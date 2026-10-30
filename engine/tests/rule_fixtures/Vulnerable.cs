// Test fixture for security_rules.json. Deliberately vulnerable; never compiled.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
using System.Data.SqlClient;
using System.Runtime.Serialization.Formatters.Binary;

class Vulnerable
{
    void Handle(SqlConnection connection, string id)
    {
        // ruleid: csharp-sql-string-building
        var command = new SqlCommand("SELECT * FROM users WHERE id = " + id, connection);
        // ok: csharp-sql-string-building
        var safe = new SqlCommand("SELECT * FROM users WHERE id = @id", connection);
        // ruleid: csharp-unsafe-deserialization
        var formatter = new BinaryFormatter();
    }
}
