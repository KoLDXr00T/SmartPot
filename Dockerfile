FROM golang:alpine AS builder

ENV GO111MODULE=on \
    CGO_ENABLED=0 \
    GOOS=linux

RUN apk add git

WORKDIR /build

# Download dependency
COPY . .
RUN go mod download


# Build
RUN go build -o main .

WORKDIR /dist

RUN cp /build/main .

# Python runtime for the python-hf LLM provider (plugins/python_hf.py)
FROM python:3.13-slim

WORKDIR /

COPY plugins/requirements.txt /plugins/requirements.txt
RUN pip install --no-cache-dir -r /plugins/requirements.txt

COPY plugins/python_hf.py /plugins/python_hf.py
COPY --from=builder /dist/main /

ENTRYPOINT ["/main"]
