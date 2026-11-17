(() => {
  const examples = [
    { link: "jira.acme.com/browse/OPS-12", to: "work", reason: "matches your rule for acme.com" },
    { link: "youtube.com/watch?v=dQw4w9WgXcQ", to: "ads", reason: "matches your rule for youtube.com" },
    { link: "calendar.google.com/event?eid=…", to: "work", reason: "invite for you@acme.com" },
    { link: "github.com/ten50nl/detour", to: "personal", reason: "94% of your visits were in this profile" },
    { link: "docs.google.com/document/d/1Bx…", to: "personal", reason: "you opened this doc here before" },
    { link: "twitch.tv/directory", to: "ads", reason: "you moved twitch.tv here once, so it remembers" },
  ];

  const figure = document.querySelector(".routes");
  const runner = figure && figure.querySelector(".runner");
  const chip = document.querySelector("[data-link]");
  const reason = document.querySelector("[data-reason]");
  const reduced = window.matchMedia("(prefers-reduced-motion: reduce)");

  function show(ex) {
    chip.textContent = ex.link;
    reason.textContent = `Opens in ${label(ex.to)}: ${ex.reason}`;
  }

  function label(id) {
    return { work: "Work", personal: "Personal", ads: "Ad-free" }[id];
  }

  function light(id) {
    figure.querySelectorAll(".track").forEach((t) => t.classList.toggle("active", t.id === `p-${id}`));
    figure.querySelectorAll(".stop").forEach((s) => s.classList.toggle("lit", s.dataset.stop === id));
  }

  function run(i) {
    const ex = examples[i % examples.length];
    show(ex);
    const path = figure.querySelector(`#p-${ex.to}`);
    if (reduced.matches) {
      light(ex.to);
      const end = path.getPointAtLength(path.getTotalLength());
      runner.setAttribute("cx", end.x);
      runner.setAttribute("cy", end.y);
      setTimeout(() => run(i + 1), 3200);
      return;
    }
    light(null);
    const length = path.getTotalLength();
    const duration = 1400;
    let start;
    function step(t) {
      start ??= t;
      const k = Math.min((t - start) / duration, 1);
      const eased = k < 0.5 ? 2 * k * k : 1 - Math.pow(-2 * k + 2, 2) / 2;
      const p = path.getPointAtLength(eased * length);
      runner.setAttribute("cx", p.x);
      runner.setAttribute("cy", p.y);
      if (k < 1) requestAnimationFrame(step);
      else {
        light(ex.to);
        setTimeout(() => run(i + 1), 1900);
      }
    }
    setTimeout(() => requestAnimationFrame(step), 500);
  }

  if (figure && runner && chip && reason) run(0);

  document.querySelectorAll("[data-copy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const text = document.getElementById(button.dataset.copy).textContent;
      try {
        await navigator.clipboard.writeText(text);
        button.textContent = "Copied";
      } catch {
        button.textContent = "Select and copy";
      }
      setTimeout(() => (button.textContent = "Copy"), 1800);
    });
  });

  const version = document.querySelector("[data-version]");
  if (version) {
    fetch("https://api.github.com/repos/ten50nl/detour/releases/latest")
      .then((r) => (r.ok ? r.json() : null))
      .then((release) => {
        if (release && release.tag_name) version.textContent = `Version ${release.tag_name.replace(/^v/, "")}, macOS 15 or later`;
      })
      .catch(() => {});
  }
})();
