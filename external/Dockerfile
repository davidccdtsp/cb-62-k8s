FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt external/requirements-otel.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-otel.txt && \
    opentelemetry-bootstrap -a install
COPY backend/app.py .
EXPOSE 8000
CMD ["opentelemetry-instrument", "uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
