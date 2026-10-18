FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod *.go ./
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /proxy .

FROM gcr.io/distroless/static:nonroot
LABEL org.opencontainers.image.source=https://github.com/dddd-zdf/background-sync-for-immich
LABEL org.opencontainers.image.description="Background Sync for Immich server side: turns iOS background uploads into Immich uploads"
LABEL org.opencontainers.image.licenses=MIT
COPY --from=build /proxy /proxy
ENTRYPOINT ["/proxy"]
