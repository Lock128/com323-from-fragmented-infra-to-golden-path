# Scaffolded by the lockhead.cloud platform — you did not write this. (Go)
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY app/go.mod ./
COPY app/*.go ./
RUN CGO_ENABLED=0 go build -o /out/${{ values.name }} .

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/${{ values.name }} /app
EXPOSE 8080
ENTRYPOINT ["/app"]
