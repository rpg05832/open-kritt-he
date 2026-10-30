// Test fixture for security_rules.json. Deliberately vulnerable; never compiled.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
package fixture

import (
	"crypto/tls"
	"database/sql"
	"fmt"
	"os/exec"
)

func handle(db *sql.DB, id string) {
	// ruleid: go-tls-verify-disabled
	_ = &tls.Config{InsecureSkipVerify: true}
	// ok: go-tls-verify-disabled
	_ = &tls.Config{MinVersion: tls.VersionTLS12}
	// ruleid: go-sql-string-building
	db.Query(fmt.Sprintf("SELECT * FROM users WHERE id = %s", id))
	// ok: go-sql-string-building
	db.Query("SELECT * FROM users WHERE id = $1", id)
	// ruleid: go-shell-command
	exec.Command("sh", "-c", "ls "+id)
	// ok: go-shell-command
	exec.Command("ls", id)
}
