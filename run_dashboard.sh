#!/bin/bash

# Get the directory where this script is located
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Set host with fallback to 127.0.0.1
if [ -n "$DASHBOARD_HOST" ]; then
    HOST_NAME="$DASHBOARD_HOST"
else
    HOST_NAME="127.0.0.1"
fi

# Set port with fallback to 8000
if [ -n "$DASHBOARD_PORT" ]; then
    PORT="$DASHBOARD_PORT"
else
    PORT="8000"
fi

# Set Python environment variables
export PYTHONPATH="${PROJECT_ROOT}/.packages"
export PYTHONDONTWRITEBYTECODE="1"

# Change to project root directory
cd "$PROJECT_ROOT" || exit 1

# Run the Django development server
python manage.py runserver "${HOST_NAME}:${PORT}" --noreload