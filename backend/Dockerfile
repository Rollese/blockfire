FROM python:3.11-slim
WORKDIR /srv
COPY pyproject.toml ./
RUN pip install --no-cache-dir . && pip install --no-cache-dir "uvicorn[standard]>=0.29"
COPY app ./app
COPY worker ./worker
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
