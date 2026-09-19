# Wijkloper API as a small container. Data (the SQLite database) lives in the
# /data volume; the reverse proxy in front of it terminates TLS.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    WIJKLOPER_DATA_DIR=/data \
    # Trust X-Forwarded-For from the proxy so rate limiting sees real client IPs.
    # Only safe because port 8000 is not published to the outside world.
    FORWARDED_ALLOW_IPS=*

WORKDIR /srv/wijkloper

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN useradd --system --uid 10001 --no-create-home wijkloper \
    && mkdir -p /data && chown wijkloper:wijkloper /data
USER wijkloper

VOLUME ["/data"]
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD python -c "import sys, urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/health', timeout=4).status == 200 else 1)"

CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
