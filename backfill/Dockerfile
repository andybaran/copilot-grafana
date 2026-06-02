FROM docker.io/library/python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir "psycopg2-binary==2.9.10"
COPY parser.py /app/parser.py
ENTRYPOINT ["python", "/app/parser.py"]
