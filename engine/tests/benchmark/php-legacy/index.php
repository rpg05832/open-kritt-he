<?php
// Benchmark project: deliberately vulnerable legacy PHP page. Never run it.
$db = new mysqli('localhost', 'app', 'app', 'shop');

$page = $_GET['page'];
include($_GET['page']);

$id = $_GET['id'];
$result = $db->query("SELECT * FROM products WHERE id = " . $id);

$cart = unserialize($_COOKIE['cart']);

echo shell_exec("convert " . $_GET['image'] . " out.png");
