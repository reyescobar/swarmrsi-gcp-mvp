FROM python:3.12-slim

RUN apt-get update && apt-get install -y --no-install-recommends git && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY control_plane/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY verifier/ /app/verifier/
ENV PYTHONUNBUFFERED=1

CMD ["python3", "-m", "verifier.four_gate_verifier"]
