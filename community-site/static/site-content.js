/* 官网内容热更新：只替换文案/链接/素材，不动社区实时 feed。 */
(function () {
  "use strict";
  var API = "https://www.dbmt999.asia/community/api/site/content";

  function get(obj, path) {
    return String(path || "").split(".").reduce(function (acc, key) {
      return acc == null ? null : acc[key];
    }, obj);
  }

  function text(v) {
    return v == null ? "" : String(v);
  }

  function setOne(el, value) {
    if (value == null) return;
    if (el.hasAttribute("data-site-html")) el.innerHTML = text(value);
    else el.textContent = text(value);
  }

  function apply(content) {
    if (!content) return;
    var seo = content.seo || {};
    if (seo.title) document.title = seo.title;
    var meta = function (sel, attr, val) {
      if (!val) return;
      var el = document.querySelector(sel);
      if (el) el.setAttribute(attr, val);
    };
    meta('meta[name="description"]', "content", seo.description);
    meta('meta[property="og:title"]', "content", seo.ogTitle);
    meta('meta[property="og:description"]', "content", seo.ogDescription);
    function absolute(v) {
      if (!v) return "";
      try { return new URL(v, location.href).href; } catch (e) { return text(v); }
    }
    meta('meta[property="og:image"]', "content", absolute(seo.ogImage));
    meta('link[rel="canonical"]', "href", absolute(seo.canonical));

    document.querySelectorAll("[data-site]").forEach(function (el) {
      setOne(el, get(content, el.getAttribute("data-site")));
    });
    document.querySelectorAll("[data-site-href]").forEach(function (el) {
      var v = get(content, el.getAttribute("data-site-href"));
      if (v) el.setAttribute("href", text(v));
    });
    document.querySelectorAll("[data-site-src]").forEach(function (el) {
      var v = get(content, el.getAttribute("data-site-src"));
      if (v) el.setAttribute("src", text(v));
    });
    document.querySelectorAll("[data-site-alt]").forEach(function (el) {
      var v = get(content, el.getAttribute("data-site-alt"));
      if (v) el.setAttribute("alt", text(v));
    });

    function navItems() {
      var items = get(content, "nav.items");
      if (!Array.isArray(items)) return;
      var desk = document.querySelector('.nav-links[data-site-list="nav.items"]');
      if (desk) {
        desk.innerHTML = items.map(function (x) {
          var href = text(x.url);
          return '<a href="' + href + '" data-section="' + href.replace(/^#/, "") + '">' + text(x.label) + "</a>";
        }).join("");
      }
      var mob = document.querySelector('#mobileMenu[data-site-list="nav.items"]');
      if (mob) {
        var foot = mob.querySelector('small[data-site="brand.mobileFoot"]');
        mob.innerHTML = items.map(function (x, i) {
          return '<a href="' + text(x.url) + '">' + text(x.label) +
            '<small style="font-size:9px;letter-spacing:.2em;color:rgba(243,241,233,.38);margin-left:10px">' +
            String(i + 1).padStart(2, "0") + "</small></a>";
        }).join("");
        if (foot) mob.appendChild(foot);
      }
    }
    navItems();

    function list(path, render) {
      document.querySelectorAll('[data-site-list="' + path + '"]').forEach(function (box) {
        var items = get(content, path);
        if (path === "hero.marquee" && Array.isArray(items)) items = items.concat(items);
        if (Array.isArray(items)) box.innerHTML = items.map(render).join("");
      });
    }
    list("hero.tags", function (x) { return "<span><i></i>" + text(x) + "</span>"; });
    list("hero.marquee", function (x) { return "<span>" + text(x) + "</span>"; });
    list("night.tags", function (x) { return "<span>" + text(x) + "</span>"; });
    list("character.profile", function (x) {
      return '<div class="profile-row"><span class="label">' + text(x.label) +
        '</span><span class="value">' + text(x.value) + "</span></div>";
    });
    list("small.items", function (x, i) {
      return '<div class="small-item"><span class="no">' + String(i + 1).padStart(2, "0") +
        '</span><div><h3>' + text(x.title) + "</h3><p>" + text(x.desc) + "</p></div></div>";
    });
    list("client.rows", function (x) {
      var tagClass = x.tone === "open" ? "open" : (x.tone === "wait" ? "wait" : "beta");
      var link = x.linkText && x.linkUrl
        ? '<a class="client-link" href="' + text(x.linkUrl) + '" target="_blank" rel="noopener">' +
          text(x.linkText) + " ↗</a>"
        : "";
      return '<div class="client-row"><div><div class="client-platform">' + text(x.platform) +
        '</div><div class="client-version">' + text(x.version) + '</div></div>' +
        '<span class="client-tag ' + tagClass + '">' + text(x.tag) + "</span>" + link + "</div>";
    });
    function footerList(path) {
      document.querySelectorAll('[data-site-list="' + path + '"]').forEach(function (col) {
        var items = get(content, path);
        if (!Array.isArray(items)) return;
        var head = col.querySelector("small");
        col.innerHTML = (head ? head.outerHTML : "") + items.map(function (x) {
          return '<a href="' + text(x.url) + '">' + text(x.label) + "</a>";
        }).join("");
      });
    }
    footerList("footer.explore");
    footerList("footer.elsewhere");

    var note = document.querySelector(".client-note[data-site-html]");
  }

  function load() {
    fetch(API, {cache: "no-store"})
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (j) { if (j && j.content) apply(j.content); })
      .catch(function () {});
  }
  load();
  setInterval(load, 30000);
  window.addEventListener("focus", load);
})();
