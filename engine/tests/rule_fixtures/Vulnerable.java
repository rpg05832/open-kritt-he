// Test fixture for security_rules.json. Deliberately vulnerable; never compiled.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
import java.io.ObjectInputStream;
import java.sql.Connection;
import java.sql.Statement;
import javax.crypto.Cipher;

class Vulnerable {
    void handle(Statement statement, Connection connection, String id, java.io.InputStream in) throws Exception {
        // ruleid: java-command-injection
        Runtime.getRuntime().exec("ping " + id);
        // ok: java-command-injection
        Runtime.getRuntime().exec("uptime");
        // ruleid: java-sql-string-building
        statement.executeQuery("SELECT * FROM users WHERE id = " + id);
        // ok: java-sql-string-building
        connection.prepareStatement("SELECT * FROM users WHERE id = ?");
        // ruleid: java-unsafe-deserialization
        ObjectInputStream stream = new ObjectInputStream(in);
        // ruleid: java-weak-cipher
        Cipher weak = Cipher.getInstance("DES");
        // ok: java-weak-cipher
        Cipher strong = Cipher.getInstance("AES/GCM/NoPadding");
    }
}
