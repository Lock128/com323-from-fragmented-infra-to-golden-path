<?php
// legacy-orders — a tiny pre-existing PHP service (orders API).
// Predates the lockhead.cloud platform; onboarded as an EXISTING service.

header('Content-Type: application/json');

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

switch ($path) {
    case '/healthz':
        echo json_encode(['status' => 'ok']);
        break;

    case '/orders':
        echo json_encode([
            'service' => 'legacy-orders',
            'runtime' => 'php-' . PHP_VERSION,
            'orders'  => [
                ['id' => 1001, 'item' => 'coffee',    'qty' => 2],
                ['id' => 1002, 'item' => 'croissant', 'qty' => 1],
            ],
        ]);
        break;

    default:
        echo json_encode([
            'service' => 'legacy-orders',
            'message' => 'pre-existing PHP service, now on lockhead.cloud',
            'runtime' => 'php-' . PHP_VERSION,
            'hostname' => gethostname(),
        ]);
}
