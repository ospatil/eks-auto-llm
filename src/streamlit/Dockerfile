FROM python:3.11-slim

WORKDIR /app

# Install deps first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# Run as non-root user for better security. Matches the securityContext.runAsUser in k8s/streamlit.yaml.
# Fixed UID (10001) is used to ensure the user has permissions to write to the mounted emptyDir volumes in the k8s deployment.
RUN useradd --create-home --uid 10001 appuser \
	&& chown -R appuser:appuser /app
USER appuser

EXPOSE 8501

# Bind to all interfaces; disable the usage stats prompt for headless runs.
ENTRYPOINT ["streamlit", "run", "app.py", \
  "--server.address=0.0.0.0", \
  "--server.port=8501", \
  "--server.headless=true", \
  "--browser.gatherUsageStats=false"]
