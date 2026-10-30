<?php
// Test fixture for security_rules.json. Deliberately vulnerable; never executed.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
function handler($db, $conn, $id) {
    // ruleid: php-command-injection
    system("ping " . $_GET['host']);
    // ok: php-command-injection
    system("uptime");
    // ruleid: php-code-injection
    eval($id);
    // ruleid: php-unserialize
    $obj = unserialize($_COOKIE['state']);
    // ok: php-unserialize
    $safe = json_decode($id, true);
    // ruleid: php-sql-string-building
    $db->query("SELECT * FROM users WHERE id = " . $id);
    // ruleid: php-sql-string-building
    mysqli_query($conn, "SELECT * FROM users WHERE id = $id");
    // ok: php-sql-string-building
    $db->query("SELECT 1");
    // ruleid: php-file-inclusion
    include($_GET['page']);
    // ok: php-file-inclusion
    include('header.php');
    // ok: php-file-inclusion
    include($pages[$_GET['page']] ?? 'home.php');
    return [$obj, $safe];
}
