FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o validation-server .

FROM scratch
COPY --from=builder /build/validation-server /validation-server
EXPOSE 8080
ENTRYPOINT ["/validation-server"]
