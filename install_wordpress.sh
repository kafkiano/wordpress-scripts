#!/usr/bin/env bash

# Usage: 
#   Install: sudo ./install-wordpress.sh site_directory [--extras]
#   Delete:  sudo ./install-wordpress.sh site_directory --delete

# Global variables
SITE_DIR=""
EXTRAS=false
DELETE=false
SITE_PATH=""
DB_NAME=""
DB_USER=""
DB_PASS=""

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        "--extras")
            EXTRAS=true
            ;;
        "--delete")
            DELETE=true
            ;;
        *)
            SITE_DIR="$arg"
            ;;
    esac
done

# Validate site directory
if [[ -z "$SITE_DIR" ]]; then
    echo "Usage:"
    echo "  Install: $0 site_directory [--extras]"
    echo "  Delete:  $0 site_directory --delete"
    echo ""
    echo "Examples:"
    echo "  $0 dev.example.com"
    echo "  $0 dev.example.com --extras"
    echo "  $0 dev.example.com --delete"
    exit 1
fi

SITE_PATH="/var/www/$SITE_DIR"
DB_NAME=$(echo "$SITE_DIR" | tr '.' '_' | tr -cd '[:alnum:]_')
DB_USER="$DB_NAME"

setup_mysql_auth() {
    # Try socket auth first, then password auth
    if mysql -u root -e "SELECT 1" &>/dev/null; then
        MYSQL_CMD="mysql"
    else
        echo "MySQL root password required (socket auth failed):"
        MYSQL_CMD="mysql -u root -p"
    fi
}

install_wordpress() {
    echo "Installing WordPress to $SITE_PATH..."
    mkdir -p "$SITE_PATH"
    curl -s https://wordpress.org/latest.tar.gz | \
        tar xz --strip-components=1 -C "$SITE_PATH"
    echo "WordPress installed successfully to $SITE_PATH"
}

install_extras() {
    echo "Installing Plugins..."
    
    # Download and install Coblocks
    echo "Downloading Coblocks..."
    curl -s -L "https://downloads.wordpress.org/plugin/coblocks.latest-stable.zip?nostats=1" -o /tmp/coblocks.zip
    unzip -q /tmp/coblocks.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/coblocks.zip

    # Download and install ImageMagic Engine
    echo "Downloading ImageMagic Engine..."
    curl -s -L "https://downloads.wordpress.org/plugin/imagemagick-engine.latest-stable.zip?nostats=1" -o /tmp/imagemagick-engine.zip
    unzip -q /tmp/imagemagick-engine.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/imagemagick-engine.zip

    # Download and install Nginx Helper
    echo "Downloading Nginx Helper..."
    curl -s -L "https://downloads.wordpress.org/plugin/nginx-helper.latest-stable.zip?nostats=1" -o /tmp/nginx-helper.zip
    unzip -q /tmp/nginx-helper.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/nginx-helper.zip

    # Download and install Redis Cache
    echo "Downloading Redis Cache..."
    curl -s -L "https://downloads.wordpress.org/plugin/redis-cache.latest-stable.zip?nostats=1" -o /tmp/redis-cache.zip
    unzip -q /tmp/redis-cache.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/redis-cache.zip

    # Download and install WooCommerce
    echo "Downloading WooCommerce..."
    curl -s -L "https://downloads.wordpress.org/plugin/woocommerce.latest-stable.zip?nostats=1" -o /tmp/woocommerce.zip
    unzip -q /tmp/woocommerce.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/woocommerce.zip

    # Download and install WP Swiper
    echo "Downloading WP Swiper..."
    curl -s -L "https://downloads.wordpress.org/plugin/wp-swiper.latest-stable.zip?nostats=1" -o /tmp/wp-swiper.zip
    unzip -q /tmp/wp-swiper.zip -d "$SITE_PATH/wp-content/plugins/"
    rm /tmp/wp-swiper.zip

    echo "Extras installed successfully!"

    # Delete Hello Dolly Plugin
    echo "Deleting Hello Dolly Plugin..."
    rm $SITE_PATH/wp-content/plugins/hello.php
}

create_database() {
    RANDOM1=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')
    RANDOM2=$(openssl rand -base64 12 | tr -dc 'A-Za-z0-9')
    DB_PASS="$RANDOM1-$RANDOM2"

    echo "Creating database: $DB_NAME"

    # Determine MySQL authentication method
    setup_mysql_auth

    SQL=$(cat <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
)
    
    echo "Executing SQL commands..."
    echo "$SQL" | $MYSQL_CMD

    if [ $? -eq 0 ]; then
        echo "Database created successfully!"
    else
        echo "Error creating database!"
        exit 1
    fi
}

delete_database() {
    echo "Removing database and user: $DB_NAME"

    # Determine MySQL authentication method
    setup_mysql_auth

    $MYSQL_CMD <<EOF
DROP DATABASE IF EXISTS \`$DB_NAME\`;
DROP USER IF EXISTS '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    echo "Database and user removed successfully!"
}

configure_wordpress() {
    echo "Configuring WordPress at $SITE_PATH..."
    
    # Move sample config to actual config
    mv "$SITE_PATH/wp-config-sample.php" "$SITE_PATH/wp-config.php"
    
    # Replace database credentials
    sed -i "s/database_name_here/$DB_NAME/" "$SITE_PATH/wp-config.php"
    sed -i "s/username_here/$DB_USER/" "$SITE_PATH/wp-config.php"
    sed -i "s/password_here/$DB_PASS/" "$SITE_PATH/wp-config.php"
    
    # Fetch and replace authentication salts
    echo "Fetching authentication salts from WordPress API..."
    SALTS=$(curl -s https://api.wordpress.org/secret-key/1.1/salt/)
    
    # Replace the entire salts block using a temporary file
    awk -v salts="$SALTS" '
    /put your unique phrase here/ && !found {
        print salts
        found = 1
        next
    }
    !found || !/put your unique phrase here/
    ' "$SITE_PATH/wp-config.php" > "$SITE_PATH/wp-config.tmp" && \
    mv "$SITE_PATH/wp-config.tmp" "$SITE_PATH/wp-config.php"
    
    # Insert Nginx Helper cache path definition if extras are enabled
    if [[ "$EXTRAS" == true ]]; then
        sed -i "/\/\* Add any custom values between this line and the \"stop editing\" line\. \*\//a define('RT_WP_NGINX_HELPER_CACHE_PATH', '$SITE_PATH/cache/');" "$SITE_PATH/wp-config.php"
    fi
    
    echo "WordPress configuration completed!"
}

set_ownership() {
    echo "Setting ownership to www-data..."
    chown -R www-data:www-data "$SITE_PATH"
}

show_summary() {
    echo ""
    echo "WordPress installation complete!"
    echo "================================"
    echo "Site URL: http://$SITE_DIR"
    echo "Install path: $SITE_PATH"
    echo "Database: $DB_NAME"
    echo "Username: $DB_USER"
    echo "Password: $DB_PASS"
    echo ""
}

delete_site() {
    echo "Deleting WordPress site: $SITE_DIR"
    echo "This will remove:"
    echo "  • Directory: $SITE_PATH"
    echo "  • Database: $DB_NAME"
    echo "  • Database user: $DB_USER"
    echo ""
    
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deletion cancelled."
        exit 0
    fi
    
    # Delete directory
    if [[ -d "$SITE_PATH" ]]; then
        echo "Removing directory: $SITE_PATH"
        rm -rf "$SITE_PATH"
    else
        echo "Directory $SITE_PATH not found, skipping."
    fi
    
    # Delete database and user
    delete_database
    
    echo ""
    echo "WordPress site deleted successfully!"
}

# Main execution
if [[ "$DELETE" == true ]]; then
    delete_site
else
    echo "WordPress Installation"
    echo "======================"
    echo "Site: $SITE_DIR"
    echo "Extras: $([[ "$EXTRAS" == true ]] && echo "Yes" || echo "No")"
    echo ""

    install_wordpress

    if [[ "$EXTRAS" == true ]]; then
        install_extras
    fi

    create_database
    configure_wordpress
    set_ownership
    show_summary
fi