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

# Default address for the Teams card's "Open SWAT board" button. Set it when you build:
#   docker build --build-arg SWAT_BOARD_PUBLIC_URL=http://swat-server.company.com:8080 -t p1-api-monitor .
# A non-empty SWAT_BOARD_PUBLIC_URL in .env overrides it at run time.
ARG SWAT_BOARD_PUBLIC_URL=http://localhost:8080
ENV SWAT_BOARD_DEFAULT_URL=${SWAT_BOARD_PUBLIC_URL}

# SWAT board
EXPOSE 8080

CMD ["python", "monitor.py"]
