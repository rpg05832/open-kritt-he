<?php
// Benchmark project: the SAFE counterpart. Any finding here is a false positive.
$db = new mysqli('localhost', 'app', 'app', 'shop');

$allowed = ['home' => 'home.php', 'about' => 'about.php'];
include($allowed[$_GET['page'] ?? 'home'] ?? 'home.php');

$statement = $db->prepare('SELECT * FROM products WHERE id = ?');
$statement->bind_param('i', $_GET['id']);
$statement->execute();

$cart = json_decode($_COOKIE['cart'] ?? '[]', true);

echo shell_exec('uptime');
