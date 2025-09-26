#!/bin/bash

# Automated HTTPS Setup Script for hermas.ai documents API
# This script sets up nginx reverse proxy with Let's Encrypt SSL
# Run as: sudo bash setup-https.sh your-email@example.com

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="api.hermas.ai"
FASTAPI_PORT="8000"
EMAIL="$1"

# Logging function
log() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   error "This script must be run as root (use sudo)"
   exit 1
fi

# Validate email parameter
if [[ -z "$EMAIL" ]]; then
    error "Usage: sudo bash setup-https.sh your-email@example.com"
    exit 1
fi

# Validate email format
if [[ ! "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    error "Invalid email format: $EMAIL"
    exit 1
fi

log "Starting HTTPS setup for $DOMAIN"
log "Email: $EMAIL"

# Check if FastAPI service is running
if ! curl -s http://127.0.0.1:$FASTAPI_PORT/health > /dev/null; then
    warning "FastAPI service is not running on port $FASTAPI_PORT"
    info "Make sure to start your Python service: python main.py"
fi

# Step 1: Update system and install packages
log "Step 1: Installing nginx and certbot..."
apt update && apt upgrade -y
apt install nginx certbot python3-certbot-nginx ufw -y

# Step 2: Configure firewall
log "Step 2: Configuring firewall..."
ufw --force enable
ufw allow 'Nginx Full'
ufw allow ssh
ufw allow 8000  # Allow direct access to FastAPI for debugging

# Step 3: Create nginx configuration
log "Step 3: Creating nginx configuration..."

# Backup existing nginx config if it exists
if [[ -f /etc/nginx/sites-available/documents-api ]]; then
    cp /etc/nginx/sites-available/documents-api /etc/nginx/sites-available/documents-api.backup.$(date +%s)
    warning "Existing nginx config backed up"
fi

# Create nginx configuration
cat > /etc/nginx/sites-available/documents-api << 'EOL'
# Rate limiting configuration
limit_req_zone $binary_remote_addr zone=api:10m rate=10r/s;

server {
    listen 80;
    server_name api.hermas.ai;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Content-Security-Policy "default-src 'self' http: https: data: blob: 'unsafe-inline'" always;

    # API endpoints
    location / {
        # Rate limiting
        limit_req zone=api burst=20 nodelay;

        # Proxy to FastAPI
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;

        # Timeout settings
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # File upload settings
        client_max_body_size 50M;

        # CORS headers
        add_header 'Access-Control-Allow-Origin' '*' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;

        # Handle preflight requests
        if ($request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '*';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }
    }

    # Health check endpoint (bypass rate limiting)
    location /health {
        proxy_pass http://127.0.0.1:8000/health;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOL

# Step 4: Enable nginx configuration
log "Step 4: Enabling nginx configuration..."

# Remove default site if it exists
if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm /etc/nginx/sites-enabled/default
    info "Removed default nginx site"
fi

# Enable our site
ln -sf /etc/nginx/sites-available/documents-api /etc/nginx/sites-enabled/

# Test nginx configuration
if nginx -t; then
    log "Nginx configuration is valid"
else
    error "Nginx configuration is invalid"
    exit 1
fi

# Step 5: Start and enable nginx
log "Step 5: Starting nginx..."
systemctl enable nginx
systemctl restart nginx

# Wait a moment for nginx to start
sleep 2

# Check nginx status
if systemctl is-active --quiet nginx; then
    log "Nginx is running successfully"
else
    error "Failed to start nginx"
    systemctl status nginx
    exit 1
fi

# Step 6: Get SSL certificate
log "Step 6: Obtaining SSL certificate from Let's Encrypt..."

# Check if domain resolves to this server
info "Checking DNS resolution for $DOMAIN..."
DOMAIN_IP=$(dig +short $DOMAIN)
SERVER_IP=$(curl -s ifconfig.me)

if [[ "$DOMAIN_IP" != "$SERVER_IP" ]]; then
    warning "DNS check: $DOMAIN resolves to $DOMAIN_IP but server IP is $SERVER_IP"
    warning "Make sure $DOMAIN points to this server's IP address"
    echo -n "Continue anyway? (y/N): "
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        info "Exiting. Please update DNS and run again."
        exit 1
    fi
fi

# Get SSL certificate
if certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email $EMAIL --redirect; then
    log "SSL certificate obtained successfully!"
else
    error "Failed to obtain SSL certificate"
    error "Please check:"
    error "1. DNS: $DOMAIN should point to this server IP ($SERVER_IP)"
    error "2. Firewall: ports 80 and 443 should be open"
    error "3. Email: $EMAIL should be valid"
    exit 1
fi

# Step 7: Set up auto-renewal
log "Step 7: Setting up SSL certificate auto-renewal..."

# Test renewal
if certbot renew --dry-run; then
    log "SSL auto-renewal test passed"
else
    warning "SSL auto-renewal test failed"
fi

# Step 8: Create systemd service for FastAPI (optional)
log "Step 8: Creating systemd service for FastAPI..."

cat > /etc/systemd/system/documents-api.service << EOL
[Unit]
Description=FastAPI Documents Service
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/documents-services
Environment=PATH=/home/ubuntu/documents-services/venv/bin
ExecStart=/home/ubuntu/documents-services/venv/bin/python main.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOL

# Create management script
log "Step 9: Creating management script..."

cat > /usr/local/bin/manage-docs-api << 'EOL'
#!/bin/bash

case "$1" in
    start)
        echo "Starting documents API..."
        systemctl start documents-api
        systemctl start nginx
        ;;
    stop)
        echo "Stopping documents API..."
        systemctl stop documents-api
        systemctl stop nginx
        ;;
    restart)
        echo "Restarting documents API..."
        systemctl restart documents-api
        systemctl restart nginx
        ;;
    status)
        echo "=== Documents API Status ==="
        systemctl status documents-api --no-pager
        echo ""
        echo "=== Nginx Status ==="
        systemctl status nginx --no-pager
        echo ""
        echo "=== SSL Certificate Status ==="
        certbot certificates
        ;;
    logs)
        echo "=== FastAPI Logs ==="
        journalctl -u documents-api -f
        ;;
    nginx-logs)
        echo "=== Nginx Access Logs ==="
        tail -f /var/log/nginx/access.log
        ;;
    test)
        echo "Testing endpoints..."
        echo "HTTP Health Check:"
        curl -i http://127.0.0.1:8000/health
        echo ""
        echo "HTTPS Health Check:"
        curl -i https://api.hermas.ai/health
        ;;
    *)
        echo "Usage: manage-docs-api {start|stop|restart|status|logs|nginx-logs|test}"
        exit 1
        ;;
esac
EOL

chmod +x /usr/local/bin/manage-docs-api

# Step 10: Final verification
log "Step 10: Running final verification..."

# Test local FastAPI
if curl -s http://127.0.0.1:$FASTAPI_PORT/health > /dev/null; then
    log "✓ FastAPI service is responding locally"
else
    warning "✗ FastAPI service is not responding locally"
fi

# Test HTTPS endpoint
sleep 5  # Give certbot time to reload nginx
if curl -s https://$DOMAIN/health > /dev/null; then
    log "✓ HTTPS endpoint is working: https://$DOMAIN/health"
else
    warning "✗ HTTPS endpoint test failed"
fi

# Final summary
log "Setup completed successfully!"
echo ""
echo -e "${GREEN}=== Setup Summary ===${NC}"
echo -e "${BLUE}Domain:${NC} https://$DOMAIN"
echo -e "${BLUE}SSL Certificate:${NC} Let's Encrypt (auto-renews)"
echo -e "${BLUE}Local FastAPI:${NC} http://127.0.0.1:$FASTAPI_PORT"
echo -e "${BLUE}Management:${NC} manage-docs-api {start|stop|restart|status|logs|test}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update your Amplify environment variable:"
echo "   NEXT_PUBLIC_PDF_CONVERTER_API_URL=https://$DOMAIN"
echo ""
echo "2. Test your API:"
echo "   curl https://$DOMAIN/health"
echo ""
echo "3. Monitor logs:"
echo "   manage-docs-api logs"
echo "   manage-docs-api nginx-logs"
echo ""
echo -e "${GREEN}Setup complete! Your API is now available at https://$DOMAIN${NC}"