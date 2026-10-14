FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod *.go ./
RUN go test ./... && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /proxy .

FROM gcr.io/distroless/static:nonroot
COPY --from=build /proxy /proxy
ENTRYPOINT ["/proxy"]
