FROM python:3.12-slim

WORKDIR /app
COPY control_plane/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY control_plane/ /app/control_plane/
ENV PYTHONUNBUFFERED=1
EXPOSE 8080

CMD ["uvicorn", "control_plane.broker_app:app", "--host", "0.0.0.0", "--port", "8080"]
