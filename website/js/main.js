// Progressive enhancement only — the page is fully readable with this
// disabled. Two things: a lightbox for tapping screenshots, and
// active-link highlighting in the top nav while scrolling.

(function () {
  const lightbox = document.getElementById("lightbox");
  const lightboxImg = document.getElementById("lightbox-img");
  if (!lightbox || !lightboxImg) return;

  document.querySelectorAll(".phone-frame img").forEach((img) => {
    img.addEventListener("click", () => {
      lightboxImg.src = img.currentSrc || img.src;
      lightboxImg.alt = img.alt;
      lightbox.classList.add("open");
    });
  });

  lightbox.addEventListener("click", () => {
    lightbox.classList.remove("open");
    lightboxImg.src = "";
  });

  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      lightbox.classList.remove("open");
      lightboxImg.src = "";
    }
  });
})();

(function () {
  const links = Array.from(document.querySelectorAll(".topnav nav a"));
  const sections = links
    .map((a) => document.querySelector(a.getAttribute("href")))
    .filter(Boolean);

  if (!sections.length || !("IntersectionObserver" in window)) return;

  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        const link = links.find((a) => a.getAttribute("href") === `#${entry.target.id}`);
        if (!link) return;
        if (entry.isIntersecting) {
          links.forEach((a) => a.style.color = "");
          link.style.color = "var(--text)";
        }
      });
    },
    { rootMargin: "-40% 0px -50% 0px" }
  );

  sections.forEach((s) => observer.observe(s));
})();
