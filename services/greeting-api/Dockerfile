FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /out/api .

FROM alpine:3.20
COPY --from=build /out/api /api
ENV PORT=8080
EXPOSE 8080
USER 1001:1001
ENTRYPOINT ["/api"]
