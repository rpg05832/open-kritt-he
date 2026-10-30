// Test fixture for security_rules.json. Deliberately vulnerable; never rendered.
// "ruleid:" = the next line must be reported, "ok:" = it must not be.
export function Comment({ html, text }) {
  return (
    <section>
      {/* ruleid: javascript-react-dangerous-html */}
      <div dangerouslySetInnerHTML={{ __html: html }} />
      {/* ok: javascript-react-dangerous-html */}
      <div>{text}</div>
    </section>
  );
}
