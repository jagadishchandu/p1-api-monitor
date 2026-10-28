FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY monitor.py .

# Run as a non-root user. The data lives in Azure Storage, so nothing is written to the image or a local folder.
RUN useradd --create-home --uid 10001 app
USER app

# Defaults for the non-secret settings. Any value passed at run time (docker compose, docker run -e, Kubernetes,
# Container Apps, Terraform) overrides these. Secrets and account URLs have no default: they must be passed in.
ENV AZURE_STORAGE_CONTAINER=p1-api-monitor \
    AZURE_STORAGE_FOLDER=p1-api-monitor \
    TEAMS_VERIFY_SSL=true \
    SMTP_PORT=587 \
    SMTP_STARTTLS=true \
    MONITOR_INTERVAL_MINUTES=15 \
    SWAT_BOARD_ENABLED=true \
    SWAT_BOARD_PORT=8080

# Default address for the Teams card's "Open SWAT board" button. Set it when you build:
#   docker build --build-arg SWAT_BOARD_PUBLIC_URL=http://swat-server.company.com:8080 -t p1-api-monitor .
# A non-empty SWAT_BOARD_PUBLIC_URL at run time overrides it.
ARG SWAT_BOARD_PUBLIC_URL=http://localhost:8080
ENV SWAT_BOARD_DEFAULT_URL=${SWAT_BOARD_PUBLIC_URL}

# SWAT board
EXPOSE 8080

CMD ["python", "monitor.py"]
