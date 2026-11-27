# Scaffolded by the lockhead.cloud platform — you did not write this. (PHP)
FROM php:8.3-cli-alpine
WORKDIR /app
COPY app/ ./
EXPOSE 8080
ENV PORT=8080
# Route every request to index.php via the built-in server's router.
ENTRYPOINT ["sh", "-c", "php -S 0.0.0.0:${PORT} index.php"]
