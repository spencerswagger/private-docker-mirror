FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential libpq-dev libmagic1 git curl \
    && rm -rf /var/lib/apt/lists/*
RUN pip install "zou==1.1.2" gunicorn gevent
RUN mkdir -p /opt/zou/previews
WORKDIR /opt/zou
EXPOSE 5000 5001
