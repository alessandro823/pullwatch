FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/pullwatchd ./cmd/pullwatchd

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /out/pullwatchd /usr/local/bin/pullwatchd
EXPOSE 8080
VOLUME /data
ENV PULLWATCH_LISTEN=:8080 \
    PULLWATCH_DATA_DIR=/data
ENTRYPOINT ["pullwatchd"]
CMD ["-config", "/config.yaml"]
