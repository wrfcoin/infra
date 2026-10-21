"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const INDEX_PATH = path.join(__dirname, "public", "index.html");
const APP_PATH = path.join(__dirname, "public", "app.js");

function extractExplorerScript() {
  const html = fs.readFileSync(INDEX_PATH, "utf8");
  assert.match(html, /<script src="\/app\.js"><\/script>/);
  return { html, script: fs.readFileSync(APP_PATH, "utf8") };
}

function createElement(initial = {}) {
  let html = "";
  return {
    className: "",
    textContent: "",
    value: "",
    addEventListener() {},
    get innerHTML() {
      return html;
    },
    set innerHTML(value) {
      html = value;
    },
    ...initial,
  };
}

test("transaction detail renders script and img onerror tx fields inert", async () => {
  const { html, script } = extractExplorerScript();
  assert.doesNotMatch(html, /onclick=/i, "explorer markup should not use inline onclick handlers");

  const payloadScript = "<script>alert('owned')</script>";
  const payloadImage = "<img src=x onerror=alert('owned')>";
  const app = createElement();
  const elements = {
    "#app": app,
    "#searchInput": createElement(),
    "#searchButton": createElement(),
    "#statusDot": createElement(),
    "#statusText": createElement(),
  };

  const requestedPaths = [];
  const context = {
    alert() {},
    clearInterval() {},
    console,
    Date,
    decodeURIComponent,
    document: {
      querySelector(selector) {
        return elements[selector] || null;
      },
    },
    encodeURIComponent,
    fetch: async (requestPath) => {
      requestedPaths.push(requestPath);
      return {
        ok: true,
        json: async () => ({
          hash: payloadImage,
          type: payloadScript,
          from: payloadImage,
          to: payloadScript,
          amount: payloadImage,
          fee: payloadScript,
          timestamp: payloadImage,
          signature: payloadScript,
          station_id: payloadImage,
          weather_data: {
            station_id: payloadImage,
            temperature: payloadScript,
            humidity: payloadImage,
            pressure: payloadScript,
            wind_speed: payloadImage,
            wind_direction: payloadScript,
            quality_score: payloadImage,
            latitude: payloadScript,
            longitude: payloadImage,
            location: payloadScript,
          },
        }),
      };
    },
    navigator: {},
    Number,
    setInterval() {
      return 1;
    },
    String,
    URL,
    window: {
      addEventListener() {},
      location: {
        hash: "#/tx/%27%29%2Calert(document.cookie)%2F%2F",
        origin: "https://explorer.test",
      },
    },
  };
  context.globalThis = context;

  vm.runInNewContext(script, context, { filename: "public/index.html <script>" });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(requestedPaths[0], "/api/transactions/%27%29%2Calert%28document.cookie%29%2F%2F");
  assert.doesNotMatch(app.innerHTML, /<script/i);
  assert.doesNotMatch(app.innerHTML, /<img/i);
  assert.doesNotMatch(app.innerHTML, /<[^>]+\sonerror\s*=/i);
  assert.match(app.innerHTML, /&lt;script&gt;alert/);
  assert.match(app.innerHTML, /&lt;img src=x onerror=alert/);
});
