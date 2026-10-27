FROM golang:1.27.3-alpine3.24 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pullwatchd ./cmd/pullwatchd

# 3.24.3 already includes ca-certificates-bundle, which the static binary uses for TLS.
FROM alpine:3.24.3
COPY --from=build /out/pullwatchd /usr/local/bin/pullwatchd
EXPOSE 8080
VOLUME /data
ENV PULLWATCH_LISTEN=:8080 \
    PULLWATCH_DATA_DIR=/data
ENTRYPOINT ["pullwatchd"]
CMD ["-config", "/config.yaml"]
