#!/bin/bash
set -euo pipefail

: "${MYSQL_SERVER_NAME:?MYSQL_SERVER_NAME is required}"
: "${MYSQL_ADMIN_USER:?MYSQL_ADMIN_USER is required}"
: "${MYSQL_ADMIN_PASSWORD:?MYSQL_ADMIN_PASSWORD is required}"
: "${MYSQL_DB_NAME:?MYSQL_DB_NAME is required}"

echo "Initializing database schema on ${MYSQL_SERVER_NAME}..."

az mysql flexible-server execute \
  --name "${MYSQL_SERVER_NAME}" \
  --admin-user "${MYSQL_ADMIN_USER}" \
  --admin-password "${MYSQL_ADMIN_PASSWORD}" \
  --database-name "${MYSQL_DB_NAME}" \
  --query-text "CREATE TABLE IF NOT EXISTS products (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    price DECIMAL(10,2) NOT NULL
  );"

echo "Schema initialization complete."
