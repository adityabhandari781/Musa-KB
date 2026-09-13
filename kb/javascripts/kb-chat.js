(() => {
  const COOLDOWN_MS = 60_000;
  const isLocalSite = ["localhost", "127.0.0.1"].includes(window.location.hostname);
  const apiUrl = window.MUSA_CHAT_API_URL || (isLocalSite ? "http://127.0.0.1:8001/api/chat" : "/api/chat");
  const clientIdKey = "musa-kb-chat-client-id";
  const cooldownKey = "musa-kb-chat-next-allowed-at";
  let clientId = localStorage.getItem(clientIdKey);
  if (!clientId) {
    clientId = crypto.randomUUID();
    localStorage.setItem(clientIdKey, clientId);
  }

  const escapeHtml = (text) => text.replace(/[&<>"]/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[char]);
  const formatInline = (text) => escapeHtml(text.trim())
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/`(.+?)`/g, "<code>$1</code>");

  const tableCells = (line) => line.trim().replace(/^\||\|$/g, "").split("|");
  const isTableDivider = (line) => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);

  function formatAnswer(text) {
    const lines = text.split("\n");
    const output = [];
    for (let index = 0; index < lines.length; index += 1) {
      // GitHub-flavored Markdown tables have a header row followed by a divider.
      if (lines[index].includes("|") && isTableDivider(lines[index + 1] || "")) {
        const headers = tableCells(lines[index]);
        const rows = [];
        index += 2;
        while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
          rows.push(tableCells(lines[index]));
          index += 1;
        }
        index -= 1;
        const headerHtml = headers.map((cell) => `<th>${formatInline(cell)}</th>`).join("");
        const rowHtml = rows.map((row) => `<tr>${headers.map((_, column) => `<td>${formatInline(row[column] || "")}</td>`).join("")}</tr>`).join("");
        output.push(`<div class="kb-chat__table-wrap"><table><thead><tr>${headerHtml}</tr></thead><tbody>${rowHtml}</tbody></table></div>`);
      } else {
        output.push(formatInline(lines[index]));
      }
    }
    return output.join("<br>");
  }

  function mount() {
    // This widget belongs only on the knowledge-base landing page, not on every
    // individual topic document. MkDocs serves this project under /Musa-KB/.
    const pagePath = window.location.pathname.replace(/index\.html$/, "");
    if (pagePath !== "/" && pagePath !== "/Musa-KB/") return;

    const host = document.createElement("section");
    host.className = "kb-chat";
    host.innerHTML = `
      <h2>Ask the knowledge base through AI</h2>
      <p class="kb-chat__intro">Ask about the material. Every answer is based on the relevant pages and includes its sources. Follow-up questions start fresh.</p>
      <form class="kb-chat__form">
        <label class="visually-hidden" for="kb-chat-question">Your question</label>
        <textarea id="kb-chat-question" maxlength="1200" required placeholder="(e.g. how can I deal with fear?)"></textarea>
        <button type="submit">Ask</button>
      </form>
      <p class="kb-chat__notice" aria-live="polite">One question per minute.</p>
      <div class="kb-chat__answer" aria-live="polite" hidden></div>`;
    // Material's content wrapper is inside <main class="md-main">. Mounting
    // here works both at the site's configured base path and during mkdocs serve.
    const content = document.querySelector(".md-content__inner") || document.querySelector("article.md-content__inner") || document.querySelector("main article");
    if (!content) return;
    content.append(host);

    const form = host.querySelector("form");
    const textarea = host.querySelector("textarea");
    const button = host.querySelector("button");
    const notice = host.querySelector(".kb-chat__notice");
    const answer = host.querySelector(".kb-chat__answer");
    let nextAllowedAt = Number(localStorage.getItem(cooldownKey)) || 0;

    const setCooldown = (expiresAt) => {
      nextAllowedAt = expiresAt;
      localStorage.setItem(cooldownKey, String(expiresAt));
    };

    const showCooldown = () => {
      const seconds = Math.ceil((nextAllowedAt - Date.now()) / 1000);
      if (seconds > 0) {
        button.disabled = true;
        notice.textContent = `Please wait ${seconds}s before asking another question.`;
        window.setTimeout(showCooldown, Math.min(1000, seconds * 1000));
      } else {
        localStorage.removeItem(cooldownKey);
        button.disabled = false;
        notice.textContent = "One question per minute.";
      }
    };

    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const question = textarea.value.trim();
      if (!question || Date.now() < nextAllowedAt) return;
      button.disabled = true;
      answer.hidden = false;
      answer.innerHTML = "<p>Finding relevant material…</p>";
      try {
        const response = await fetch(apiUrl, {
          method: "POST",
          headers: { "Content-Type": "application/json", "X-Client-Id": clientId },
          body: JSON.stringify({ question }),
        });
        const data = await response.json().catch(() => ({}));
        if (response.status === 429) {
          setCooldown(Date.now() + (data.retry_after_seconds || 60) * 1000);
          answer.innerHTML = `<p>${escapeHtml(data.error || "Please wait before asking again.")}</p>`;
          showCooldown();
          return;
        }
        if (!response.ok) throw new Error(data.error || "The chat service is unavailable.");
        setCooldown(Date.now() + COOLDOWN_MS);
        const sources = (data.sources || []).map((source, index) =>
          `<li><a href="${escapeHtml(source.url)}">[${index + 1}] ${escapeHtml(source.title)}</a></li>`
        ).join("");
        answer.innerHTML = `<div class="kb-chat__response">${formatAnswer(data.answer)}</div><h3>Sources</h3><ol>${sources}</ol>`;
        showCooldown();
      } catch (error) {
        answer.innerHTML = `<p>${escapeHtml(error.message)}</p>`;
        button.disabled = false;
        notice.textContent = "Could not contact the chat service. Please try again.";
      }
    });

    // Restore a running countdown after a page refresh.
    showCooldown();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", mount);
  else mount();
})();
