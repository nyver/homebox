FROM golang:1.26-bookworm AS build

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/homebox ./cmd/homebox

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=build /out/homebox /homebox
USER nonroot:nonroot
ENTRYPOINT ["/homebox"]
CMD ["server", "--config", "/etc/homebox/homebox.yaml"]
