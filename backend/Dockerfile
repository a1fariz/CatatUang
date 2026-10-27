FROM golang:1.27.3-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/api ./cmd/api \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/migrate ./cmd/migrate \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cleanup ./cmd/cleanup \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/mail-worker ./cmd/mail-worker \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ops-status ./cmd/ops-status \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/backup-check ./cmd/backup-check \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/sync-dataset ./cmd/sync-dataset \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/healthcheck ./cmd/healthcheck

FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/ /app/
USER 65532:65532
EXPOSE 8080
STOPSIGNAL SIGTERM
ENTRYPOINT ["/app/api"]
