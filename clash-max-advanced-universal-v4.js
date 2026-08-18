// Sub-Store 高级通用覆写 v4（无自定义直连 / 分组格式修复）
// 兼容普通文件 operator(input) 与 Mihomo 配置 main(config) 两种执行路径。
// 功能：三订阅 Provider、台湾/其他节点组、Emby 分组与 Emby 规则。

const SUBSCRIPTIONS = [
  {
    name: "良心云",
    prefix: "良心 ",
    url: "https://sub.876767.xyz/share/sub/liangxin?token=liangxin",
    path: "./proxy_provider/liangxin.yaml",
  },
  {
    name: "守候网络",
    prefix: "守候 ",
    url: "https://sub.876767.xyz/share/sub/shouhou?token=shouhou",
    path: "./proxy_provider/shouhou.yaml",
  },
  {
    name: "白嫖机场",
    prefix: "白嫖",
    url: "https://sub.876767.xyz/share/sub/pqjc?token=bp",
    path: "./proxy_provider/baipiao.yaml",
  },
];

const PLACEHOLDER_PROVIDER = "我的节点";
const TAIWAN_GROUP = "🇹🇼 台湾节点";
const OTHER_GROUP = "♾️ 其他节点";
const BASE_REGION_GROUPS = [
  "🇭🇰 香港节点",
  "🇺🇸 美国节点",
  "🇯🇵 日本节点",
  "🇰🇷 韩国节点",
  "🇸🇬 新加坡节点",
];
const ALL_REGION_GROUPS = [TAIWAN_GROUP, ...BASE_REGION_GROUPS, OTHER_GROUP];

const TAIWAN_FILTER =
  "(?i)(🇹🇼|台湾|台灣|臺灣|台北|臺北|新北|彰化|高雄|台中|臺中|\\bTW\\b|Taiwan|Taipei)";
const TAIWAN_ICON =
  "https://cdn.jsdelivr.net/gh/GitMetaio/Surfing@rm/Home/icon/CN.svg";
const OTHER_EXCLUDE_FILTER =
  "(?i)(港|HK|Hong Kong|HongKong|日本|川日|东京|大阪|泉日|埼玉|沪日|深日|[^-]日|JP|Japan|美|波特兰|达拉斯|俄勒冈|凤凰城|费利蒙|硅谷|拉斯维加斯|洛杉矶|圣何塞|圣克拉拉|西雅图|芝加哥|US|United States|韩国|韓國|韩|韓|首尔|首爾|KR|Korea|台|臺|新北|彰化|TW|Taiwan|Taipei|新加坡|坡|狮城|獅城|SG|Singapore|灾|网易|Netease|套餐|重置|剩余|到期|订阅|群|账户|流量|有效期|时间|官网|拒绝|DNS|网址|售|防失)";
const OTHER_ICON =
  "https://cdn.jsdelivr.net/gh/GitMetaio/Surfing@rm/Home/icon/Globe.svg";
const EMBY_ICON =
  "https://pub-8feead0908f649a8b94397f152fb9cba.r2.dev/emby.png";

const EMBY_RULE_URL =
  "https://raw.githubusercontent.com/Wo254992/rule-set/main/userEmby.list";
const EMBY_FALLBACK_YAML_URL =
  "https://raw.githubusercontent.com/Wo254992/rule-set/main/Emby.yaml";

const CLASSICAL_RULE_TYPES = new Set([
  "DOMAIN",
  "DOMAIN-SUFFIX",
  "DOMAIN-KEYWORD",
  "DOMAIN-REGEX",
  "GEOSITE",
  "IP-CIDR",
  "IP-CIDR6",
  "IP-SUFFIX",
  "GEOIP",
  "IP-ASN",
  "SRC-IP-CIDR",
  "SRC-IP-CIDR6",
  "SRC-PORT",
  "DST-PORT",
  "IN-PORT",
  "PROCESS-NAME",
  "PROCESS-NAME-REGEX",
  "PROCESS-PATH",
  "PROCESS-PATH-REGEX",
  "NETWORK",
  "NETWORK-TYPE",
  "DSCP",
  "UID",
  "IN-TYPE",
  "IN-NAME",
  "IN-USER",
]);

function expandMerge(obj) {
  if (!obj || typeof obj !== "object" || Array.isArray(obj)) return {};
  const merged = obj["<<"];
  if (!merged || typeof merged !== "object" || Array.isArray(merged)) {
    return { ...obj };
  }
  const result = { ...merged, ...obj };
  delete result["<<"];
  return result;
}

function insertAfterUnique(values, after, value) {
  const result = Array.isArray(values)
    ? values.filter((item) => item !== value)
    : [];
  const index = result.indexOf(after);
  result.splice(index === -1 ? result.length : index + 1, 0, value);
  return result;
}

function configureSubscriptions(config) {
  const providers =
    config["proxy-providers"] &&
    typeof config["proxy-providers"] === "object" &&
    !Array.isArray(config["proxy-providers"])
      ? config["proxy-providers"]
      : {};

  const placeholder = expandMerge(providers[PLACEHOLDER_PROVIDER]);
  const fallbackTemplate = {
    type: "http",
    interval: 86400,
    "health-check": {
      enable: true,
      url: "http://connectivitycheck.gstatic.com/generate_204",
      interval: 60,
    },
  };
  const template = { ...fallbackTemplate, ...placeholder };

  for (const sub of SUBSCRIPTIONS) {
    const existing = expandMerge(providers[sub.name]);
    const inherited = { ...template, ...existing };
    const inheritedOverride =
      inherited.override &&
      typeof inherited.override === "object" &&
      !Array.isArray(inherited.override)
        ? inherited.override
        : {};

    providers[sub.name] = {
      ...inherited,
      type: inherited.type || "http",
      url: sub.url,
      path: sub.path,
      override: {
        ...inheritedOverride,
        "additional-prefix": sub.prefix,
      },
    };
  }

  delete providers[PLACEHOLDER_PROVIDER];
  config["proxy-providers"] = providers;
}

function buildTaiwanGroup(existingTaiwan, hongKongGroup) {
  const fallback = {
    type: "fallback",
    interval: 5,
    lazy: true,
    url: "http://cp.cloudflare.com/generate_204",
    "disable-udp": false,
    timeout: 3000,
    "max-failed-times": 2,
    hidden: false,
    "include-all-providers": true,
  };

  const inherited = {
    ...fallback,
    ...expandMerge(hongKongGroup),
    ...expandMerge(existingTaiwan),
  };
  delete inherited.name;

  return {
    name: TAIWAN_GROUP,
    ...inherited,
    filter: TAIWAN_FILTER,
    icon: TAIWAN_ICON,
    "include-all-providers": true,
  };
}

function buildOtherGroup(existingOther, hongKongGroup) {
  const inherited = {
    ...buildTaiwanGroup(null, hongKongGroup),
    ...expandMerge(existingOther),
  };
  delete inherited.name;
  delete inherited.filter;

  return {
    name: OTHER_GROUP,
    ...inherited,
    "exclude-filter": OTHER_EXCLUDE_FILTER,
    icon: OTHER_ICON,
    "include-all-providers": true,
  };
}

function buildEmbyGroup(existingEmby) {
  const group = {
    ...expandMerge(existingEmby),
    name: "Emby",
    type: "select",
    proxies: [
      "Proxy",
      TAIWAN_GROUP,
      "🇭🇰 香港节点",
      "🇸🇬 新加坡节点",
      "🇯🇵 日本节点",
      "🇺🇸 美国节点",
      "🇰🇷 韩国节点",
      OTHER_GROUP,
      "DIRECT",
    ],
    icon: EMBY_ICON,
  };

  for (const key of [
    "use",
    "filter",
    "exclude-filter",
    "include-filter",
    "include-all",
    "include-all-providers",
    "url",
    "interval",
    "lazy",
    "timeout",
    "max-failed-times",
    "disable-udp",
    "hidden",
  ]) {
    delete group[key];
  }
  return group;
}

function configureGroups(config) {
  let groups = Array.isArray(config["proxy-groups"])
    ? config["proxy-groups"].map(expandMerge)
    : [];

  const existingTaiwan = groups.find((group) => group.name === TAIWAN_GROUP);
  const existingOther = groups.find((group) => group.name === OTHER_GROUP);
  const existingEmby = groups.find((group) => group.name === "Emby");
  const hongKongGroup = groups.find(
    (group) => group.name === "🇭🇰 香港节点",
  );

  groups = groups.filter(
    (group) =>
      group.name !== TAIWAN_GROUP &&
      group.name !== OTHER_GROUP &&
      group.name !== "Emby",
  );

  groups = groups.map((group) => {
    if (
      Array.isArray(group.proxies) &&
      BASE_REGION_GROUPS.some((name) => group.proxies.includes(name))
    ) {
      group.proxies = insertAfterUnique(
        group.proxies,
        "🇭🇰 香港节点",
        TAIWAN_GROUP,
      );
      group.proxies = insertAfterUnique(
        group.proxies,
        "🇸🇬 新加坡节点",
        OTHER_GROUP,
      );
    }
    if (ALL_REGION_GROUPS.includes(group.name)) {
      group["include-all-providers"] = true;
    }
    return group;
  });

  const taiwan = buildTaiwanGroup(existingTaiwan, hongKongGroup);
  const hongKongIndex = groups.findIndex(
    (group) => group.name === "🇭🇰 香港节点",
  );
  groups.splice(hongKongIndex === -1 ? groups.length : hongKongIndex + 1, 0, taiwan);

  const other = buildOtherGroup(existingOther, hongKongGroup);
  const singaporeIndex = groups.findIndex(
    (group) => group.name === "🇸🇬 新加坡节点",
  );
  groups.splice(
    singaporeIndex === -1 ? groups.length : singaporeIndex + 1,
    0,
    other,
  );

  const emby = buildEmbyGroup(existingEmby);
  const telegramIndex = groups.findIndex((group) => group.name === "Telegram");
  groups.splice(telegramIndex === -1 ? groups.length : telegramIndex + 1, 0, emby);

  config["proxy-groups"] = groups;
}

function parseClassicalRules(text, sourceName) {
  const rules = [];
  const seen = new Set();

  for (const rawLine of String(text || "").split(/\r?\n/)) {
    let line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;

    // 修复旧 userEmby.list 中已确认的拼写错误。
    line = line.replace(/^DOMAIN-KAYWORD,/i, "DOMAIN-KEYWORD,");

    const type = line.split(",", 1)[0].toUpperCase();
    if (!CLASSICAL_RULE_TYPES.has(type)) {
      throw new Error(`${sourceName} 含不支持的规则类型: ${type}`);
    }
    if (line.indexOf(",") === -1) {
      throw new Error(`${sourceName} 含格式不完整的规则`);
    }

    if (!seen.has(line)) {
      seen.add(line);
      rules.push(line);
    }
  }

  if (!rules.length) throw new Error(`${sourceName} 没有有效规则`);
  return rules;
}

function getCachedRules(cacheKey) {
  try {
    if (typeof scriptResourceCache === "undefined") return null;
    const cached = scriptResourceCache.get(cacheKey);
    return Array.isArray(cached) && cached.length ? cached : null;
  } catch (_) {
    return null;
  }
}

function setCachedRules(cacheKey, rules) {
  try {
    if (typeof scriptResourceCache !== "undefined") {
      scriptResourceCache.set(cacheKey, rules, 7 * 24 * 60 * 60 * 1000);
    }
  } catch (_) {}
}

async function fetchText(url) {
  if (
    typeof $substore === "undefined" ||
    !$substore.http ||
    typeof $substore.http.get !== "function"
  ) {
    throw new Error("当前脚本环境没有 Sub-Store HTTP API");
  }

  const response = await $substore.http.get({
    url,
    headers: { "user-agent": "Sub-Store Mihomo Override" },
    timeout: 15000,
  });
  const status = Number(response && (response.statusCode || response.status));
  if (status && (status < 200 || status >= 300)) {
    throw new Error(`规则源返回 HTTP ${status}`);
  }
  const body = response && response.body;
  if (typeof body !== "string" || !body.trim()) {
    throw new Error("规则源返回空内容");
  }
  return body;
}

async function loadRulePayload(url, sourceName, cacheKey) {
  try {
    const rules = parseClassicalRules(await fetchText(url), sourceName);
    setCachedRules(cacheKey, rules);
    return rules;
  } catch (error) {
    const cached = getCachedRules(cacheKey);
    if (cached) return cached;
    console.log(`[Clash_Max 覆写] ${sourceName} 拉取失败，使用兼容回退`);
    return null;
  }
}

function buildHttpRuleProvider({ url, path, format }) {
  return {
    type: "http",
    behavior: "classical",
    format,
    interval: 86400,
    proxy: "Proxy",
    url,
    path,
  };
}

async function configureRuleProvidersAndRules(config) {
  const embyPayload = await loadRulePayload(
    EMBY_RULE_URL,
    "Emby 规则",
    "clash-max:emby:v1",
  );

  const providers =
    config["rule-providers"] &&
    typeof config["rule-providers"] === "object" &&
    !Array.isArray(config["rule-providers"])
      ? config["rule-providers"]
      : {};

  // 清理上一版脚本可能已经写入的自定义直连 Provider。
  delete providers.CustomDirect;

  providers.Emby = embyPayload
    ? {
        type: "inline",
        behavior: "classical",
        payload: embyPayload,
      }
    : buildHttpRuleProvider({
        url: EMBY_FALLBACK_YAML_URL,
        path: "./RuleSet/Emby.yaml",
        format: "yaml",
      });

  config["rule-providers"] = providers;

  const managedRules = [
    "DOMAIN-KEYWORD,speedtest,Emby",
    "RULE-SET,Emby,Emby",
  ];
  const rules = (Array.isArray(config.rules) ? config.rules : []).filter(
    (rule) =>
      typeof rule !== "string" ||
      (!/^RULE-SET,(CustomDirect|Emby),/.test(rule) &&
        rule !== "DOMAIN-KEYWORD,speedtest,Emby" &&
        rule !== "DOMAIN-KAYWORD,speedtest,Emby"),
  );

  const lanIndex = rules.findIndex(
    (rule) => typeof rule === "string" && /^RULE-SET,LAN,/.test(rule),
  );
  rules.splice(lanIndex === -1 ? 0 : lanIndex + 1, 0, ...managedRules);
  config.rules = rules;
}

async function transformConfig(config) {
  if (!config || typeof config !== "object" || Array.isArray(config)) {
    config = {};
  }

  configureSubscriptions(config);
  configureGroups(config);
  await configureRuleProvidersAndRules(config);
  return config;
}

// Mihomo 配置文件入口。
async function main(config) {
  return transformConfig(config);
}

function getYamlApi() {
  const yamlApi =
    typeof yaml !== "undefined" && yaml
      ? yaml
      : typeof ProxyUtils !== "undefined" && ProxyUtils.yaml
        ? ProxyUtils.yaml
        : null;
  if (!yamlApi) throw new Error("Sub-Store YAML API 不可用");
  return yamlApi;
}

async function rewriteContent(content) {
  const yamlApi = getYamlApi();
  const load = yamlApi.safeLoad || yamlApi.load || yamlApi.parse;
  const dump = yamlApi.safeDump || yamlApi.dump || yamlApi.stringify;
  if (typeof load !== "function" || typeof dump !== "function") {
    throw new Error("Sub-Store YAML API 缺少 load/dump");
  }

  const config = load.call(yamlApi, content) || {};
  return dump.call(yamlApi, await transformConfig(config));
}

// 普通文件入口；解决 raw YAML 未被识别成 mihomoConfig 时 main 不执行的问题。
async function operator(input) {
  if (!input || typeof input !== "object" || typeof input.$content !== "string") {
    return input;
  }
  input.$content = await rewriteContent(input.$content);
  return input;
}
