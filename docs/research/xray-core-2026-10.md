# Xray-core как основное ядро KillSwitch (2026-10-10)

Статус: исследование, код не менялся, ничего не решено. Продолжает
[multi-core-2026-10.md](multi-core-2026-10.md) (там матрица протоколов и вариант «Xray за mihomo») и
issues #10, #19, #31. Вопрос владельца: «последнее современное ядро Xray, установленное как надо».
Владелец один, в Беларуси; сервер в Литве на Remnawave 3.4.5 (VLESS Reality, xHTTP); Happ работает
надёжно, KillSwitch на mihomo оставляет Мак без интернета.

Метки: **[измерено]** — проверено здесь (GitHub API, исходники тега, бинарник на этом Маке);
**[документация]** — прочитано в документации/README/исходниках, не запускалось;
**[неизвестно]** — не проверено, нужна проверка.

## 0. Коротко

- Последний Xray-core: **v26.10.10** (10.10.2026, prerelease). Все теги после v26.3.27 помечены
  prerelease; «latest stable» на GitHub — v26.3.27, но в нём нет того, что нам нужно на macOS.
- В Xray **есть свой TUN на macOS** (`"protocol": "tun"`), с v26.6.27 он сам ставит маршруты
  (`autoSystemRoutingTable`) и привязывает собственные сокеты Xray к физическому интерфейсу
  (`autoOutboundsInterface`, `IP_BOUND_IF`) — петли нет без исключения адресов серверов.
  С v26.7.11 работает правило маршрутизации `process` на macOS (программы мимо VPN).
- **Happ 6.0.0 на этом Маке — это libXray внутри NetworkExtension** (packet-tunnel), с пакетом
  `xray-core/proxy/tun` и ключом `xray.tun.fd`: то есть тот же Xray-TUN, только utun ему даёт
  NetworkExtension.
- Remnawave отдаёт Xray-клиентам **полный Xray JSON** (массив конфигов, по одному на хост, с
  `dns`, `routing`, балансировщиком и observatory). Формат выбирается по User-Agent, настройке
  `serveJsonAtBaseSubscription` или пути `/api/sub/<shortUuid>/json`.
- pf kill switch можно оставить **без изменений**: Xray запускается тем же launchd-заданием с gid
  `_ksvpn`, а `gateway: ["198.18.128.0/30"]` даёт utun локальный адрес `198.18.128.1` (= наш
  `CORE_TUN_ADDR`), так что `vpn_ifaces`/`foreign_tuns` узнают туннель как сейчас.
- Рекомендация: основной режим — **чистый Xray-TUN** (как Happ), mihomo оставить вторым
  вариантом в настройке. Это расходится с решением в #10/#31 («Xray за mihomo» по умолчанию);
  причины в §6.1, решать владельцу.

## 1. Версия и файлы

| Факт | Значение | Метка |
|---|---|---|
| Последний тег | v26.10.10, 2026-10-10 09:22 UTC, prerelease=true | измерено (`gh api repos/XTLS/Xray-core/releases`) |
| Предыдущие | v26.9.30 (30.09), v26.9.9, v26.9.8, v26.7.28, v26.7.11, v26.6.27 — все prerelease | измерено |
| «Latest» без prerelease | v26.3.27 (27.03.2026) | измерено (`releases/latest`) |
| Ассет macOS arm64 | `Xray-macos-arm64-v8a.zip`, 20 646 271 байт (v26.10.10) | измерено |
| sha256 zip v26.10.10 | `7b1711eaeefd90f27082cf49c311aa57dad44ac13146faab3f0c1601158ea6c8` (совпадает в API digest и в `.dgst`: там MD5/SHA1/SHA2-256/SHA2-512) | измерено |
| sha256 zip v26.9.30 | `4b363bd924df5bf09f87bd445755ff8e5742b9a8a0480cda261061416c3c7dce` (20 014 264 байт) | измерено (API digest) |
| sha256 zip v26.3.27 | `2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf` | измерено (API digest) |
| Лицензия | MPL-2.0 | измерено (`gh api repos/XTLS/Xray-core`) |
| Release notes | в теле релизов только спонсоры и «See next release»; изменения смотреть через `compare` | измерено |
| Размер распакованного бинарника, что ещё лежит в zip (geoip/geosite) | не распаковывали | неизвестно |

Выбор пина: нужен **≥ v26.7.11** (маршруты TUN на macOS — v26.6.27, `process` на macOS — v26.7.11).
Предлагаю v26.9.30 (10 дней, после него только исправления: gRPC redial, XDNS, Windows TUN,
iOS fd) или v26.10.10 через неделю без регрессий. Ключи конфигов меняются от тега к тегу
(в v26.10.10: XDNS `name`→`names`, `type`+`addr`→`addrs`; Windows `autoSystemDNS` переименован) —
обновлять ядро только вместе с приложением и тестами конфигов (`xray run -test -c`).

Источники: https://github.com/XTLS/Xray-core/releases/tag/v26.10.10 ,
`gh api repos/XTLS/Xray-core/compare/v26.7.28...v26.10.10`.

## 2. TUN на macOS

### 2.1 Что есть в Xray (тег v26.10.10)

- `proxy/tun/tun_darwin.go`: создаёт свой utun (имя `utunN`; без `name` выбирается свободный
  `utun10…utun1024`), стек gVisor (`stack_gvisor.go`), IPv4/IPv6, TCP/UDP, ICMP echo (ответ
  генерируется локально). **документация** (`proxy/tun/README.md`, `infra/conf/tun.go`).
- История: macOS — PR #5559 (18.01.2026, первый тег v26.1.18); `autoSystemRoutingTable` и
  `autoOutboundsInterface` на macOS — PR #6366 (24.06.2026, тег v26.6.27); доводка `gateway` и
  маршрутов на macOS — #6434 (v26.7.11); kqueue вместо busy-spin — #6580; счётчики трафика TUN —
  #6349. **измерено** (`gh api commits?path=proxy/tun/tun_darwin.go`, `compare`).
- Поля (`infra/conf/tun.go`): `name`, `mtu` (по умолчанию 1500), `gateway` (на macOS берётся первый
  IPv4-префикс: первый адрес — удалённый, следующий — локальный; по умолчанию `169.254.10.1/30`),
  `dns` (**на macOS системный DNS не меняет**), `userLevel`, `autoSystemRoutingTable`,
  `autoOutboundsInterface` (если задан `autoSystemRoutingTable`, по умолчанию `"auto"`),
  `autoSystemDnsToGateway` (только Linux), `autoSystemWfpBlockLeak` (только Windows). **документация (исходник)**.
- `autoSystemRoutingTable: ["0.0.0.0/0"]` на macOS раскладывается в 8 маршрутов
  `1/8, 2/7, 4/6, 8/5, 16/4, 32/3, 64/2, 128/1` через шлюз TUN — уже, чем default, поэтому
  маршруты подключённой LAN (`192.168.x.0/24`) остаются на Wi‑Fi; снимаются при остановке Xray
  (кроме SIGKILL — **неизвестно**, как поведут себя маршруты после `kill -9`; utun исчезнет вместе с
  процессом, маршруты на исчезнувший интерфейс macOS удаляет сам — проверить). **документация (исходник)**.
- `autoOutboundsInterface: "auto"`: Xray находит интерфейс default-маршрута (не TUN), следит за
  изменениями маршрутов (AF_ROUTE) и регистрирует **глобальный** dialer-controller, который ставит
  `IP_BOUND_IF`/`IPV6_BOUND_IF` на каждый исходящий сокет Xray (outbound'ы, freedom, DNS) —
  трафик самого Xray не уходит в TUN. **документация (исходник `handler.go`, `tun_darwin.go`)**;
  что DNS-клиент Xray тоже идёт через этот controller — **неизвестно**, проверить.
- Нужен root (utun и маршруты) — наше ядро и так root (launchd `UserName root`). **документация**.
- Ограничения из README: TUN «для профессионалов», SYN-ACK на любой адрес (соединение
  «открывается», даже если хоста нет), из ICMP только echo. Системный DNS на macOS не трогает —
  это делает наш `ks` (`dns_apply`), как для mihomo.

### 2.2 Классический путь (tun2socks / hev-socks5-tunnel / sing-box) и что делают клиенты

- Happ 6.0.0 (`/Applications/Happ.app`): `Tunnel.appex` с `NSExtensionPointIdentifier =
  com.apple.networkextension.packet-tunnel`, entitlement `packet-tunnel-provider`, песочница;
  `go version -m Tunnel` → `path github.com/xtls/libxray`, `dep github.com/xtls/xray-core`
  (replace, версия не видна), gVisor 2026-01-22; в строках 274 символа `xray-core/proxy/tun`,
  `xray.tun.fd`, а также немного `tun2socks` (SocksUdpGwClient). **измерено**. Вывод: Happ на macOS
  отдаёт fd utun из NetworkExtension в Xray-TUN (режим «iOS» из README); точный путь
  (Xray-TUN или tun2socks) по строкам не доказан — **частично неизвестно**.
- Streisand: `PacketTunnel.appex` (NetworkExtension). **измерено** (что внутри — не смотрели).
- NetworkExtension для KillSwitch не нужен и не подходит: у нас уже root-ядро через launchd, pf и
  фильтр контента; NE потребовал бы App Group/провижининг и сломал бы модель «ядро = gid `_ksvpn`».
  Xray-TUN в root-процессе даёт то же ядро, что у Happ, без NE.
- tun2socks/hev-socks5-tunnel перед SOCKS-входом Xray больше не нужны: это лишний процесс и лишняя
  подпись; их смысл был в отсутствии TUN в Xray, которого больше нет.

## 3. Что отдаёт подписка (Remnawave 3.4.5)

Источник: `remnawave/backend` тег 3.4.5 (`src/modules/subscription/subscription.service.ts`,
`subscription-response-rules/services/response-rules-matcher.service.ts`,
`subscription-template/constants/extended-clients.ts`,
`subscription-template/generators/xray-json.generator.service.ts`). **документация (исходник)**.

- Тип ответа выбирается: (1) правилами Response Rules (SRR) по заголовкам, в т.ч. User-Agent;
  (2) путём `/api/sub/<shortUuid>/<clientType>`, где `clientType` ∈ `json` (Xray JSON),
  `v2ray-json`, `mihomo`, `singbox`, `stash`, `clash` — если в SRR не стоит
  `disableSubscriptionAccessByPath` (тогда BLOCK); (3) если ответ — `XRAY_BASE64` и включено
  `serveJsonAtBaseSubscription`, то клиентам из списка JSON-fallback отдаётся `XRAY_JSON`:
  UA `^Happ/`, `^INCY/`, `^[Ss]treisand`, `^V2Box`, `^v2rayNG/x.y.z`, `^v2rayN/x.y.z`,
  `^v2plus/x.y.z`, `^ktor-client`, `^io.github.saeeddev94.xray/`.
- `XRAY_JSON` — **массив полных конфигов Xray**, по одному на видимый хост: шаблон + `outbounds`
  хоста (тег `proxy`) или, при `remnawave.injectHosts`, все подходящие хосты с их тегами;
  поле `remarks` (имя), `meta.serverDescription` для «extended» клиентов (Happ, INCY, FlClashX…).
  Хост может нести свой шаблон и `finalmask` (`host.streamOverrides.finalMask`).
- Шаблон владельца (`~/проекты ai/настройка нод/vpn/subscription-templates/lithuania.json`,
  апрель 2026 — живой шаблон панели мог измениться, **неизвестно**): ключи `burstObservatory,
  dns, inbounds, outbounds, policy, remnawave, routing`; inbound `socks-in` 127.0.0.1:10808 со
  `sniffing {destOverride [http,tls,quic], routeOnly true}`; outbounds `direct` (freedom),
  `block`, `dns-out`; DNS: `77.88.8.8` для `geosite:category-ru`, `apple`, `steam` и нескольких
  доменов (`skipFallback`), `8.8.8.8`, `1.1.1.1`, `queryStrategy UseIPv4`; routing
  `domainStrategy IPIfNonMatch`, балансировщик `country-lb` (leastLoad по `LT_`, fallback
  `LT_1`), правила: DNS-серверы по `inboundTag` (direct-dns → direct, остальные → балансировщик),
  `port 53 → dns-out`, реклама → block, private/LAN → direct, RU-сервисы/`geosite:category-ru` →
  direct, всё остальное → `country-lb`. `injectHosts` по `^LT_`. **измерено (файл)**.
- Беларусь: в этом шаблоне нет `geoip:by` / `domain:by` в direct (есть только `bsu.by` в DNS).
  По ADR 0013 правила только из подписки — значит «BY напрямую» надо добавить в шаблон панели,
  не в приложение. **измерено (файл)**.
- Клиент (Happ и мы) **заменяет `inbounds`** шаблона своими (TUN + наши служебные), остальное
  берёт как есть.

### 3.1 Geodata для Xray

Xray читает `geosite.dat`/`geoip.dat` (формат v2ray), не `geoip.metadb`.

| Файл | sha256 (10.10.2026) | Метка |
|---|---|---|
| MetaCubeX meta-rules-dat `geosite.dat` (тег `latest`, 4 290 986 б) | `e0ad83c5…aadea59` — **тот же файл, что уже запинен в `Helper/fetch-geodata.sh`** | измерено |
| MetaCubeX `geoip.dat` (16 583 067 б) | `116cc0f0…df6093` | измерено |
| Loyalsoldier v2ray-rules-dat `geoip.dat` (тег 202610092207) | `116cc0f0…df6093` — побайтно тот же, что у MetaCubeX | измерено |
| runetfreedom russia-v2ray-rules-dat `geosite.dat` / `geoip.dat` (тег 202610101926, 73.7 / 18.0 МБ) | `76fdbe01…a537cd` / `12c183f9…28d3baf` | измерено |

- runetfreedom: geosite = все категории v2fly + `ru-blocked`, `ru-available-only-inside`,
  `category-ads-all`…; geoip = списки блокировок + ASN-категории (cloudflare, telegram, yandex…),
  страны в README не названы; обновление каждые 6 ч. **документация (README)**.
- Шаблону владельца нужны `geosite:category-ru`, `apple`, `steam`, `youtube` — есть в geosite
  MetaCubeX (уже поставляем). Для `geoip:ru`/`geoip:by` нужен `geoip.dat` MetaCubeX/Loyalsoldier;
  что в нём есть `by` — **неизвестно**, проверить `xray run -test` с правилом `geoip:by`.
- Предложение: добавить в `fetch-geodata.sh` `geoip.dat` того же коммита MetaCubeX (пин sha256),
  geosite не дублировать. runetfreedom (73 МБ) — только если шаблон панели начнёт ссылаться на
  `ru-blocked` и т.п. Xray ищет файлы в `XRAY_LOCATION_ASSET` (или рядом с бинарником) —
  **документация**, путь задать явно через env в plist.

## 4. DNS, IPv6, MTU, sniffing, kill switch

- **DNS.** Оставить `dns_apply` (системный DNS → 127.0.0.1) и добавить наш inbound
  `{"tag":"ks-dns","protocol":"tunnel","listen":"127.0.0.1","port":53,"settings":{"address":"1.1.1.1","port":53,"network":"tcp,udp"}}`
  (`tunnel` = новое имя `dokodemo-door`, оба ключа есть в `infra/conf/xray.go` v26.10.10 — **измерено**)
  и наше первое правило `inboundTag ks-dns → dns-out`. DNS, который всё же попал в TUN, ловит
  правило шаблона `port 53 → dns-out`. Дальше решают серверы `dns` подписки (77.88.8.8 через
  direct, остальные через балансировщик) — как в Happ. Поведение `dns`-outbound на не-A/AAAA
  запросах (`nonIPQuery`) — **неизвестно**, проверить.
- **FakeDNS не нужен**: шаблон работает на реальных IP + sniffing `routeOnly` + `IPIfNonMatch`.
  FakeDNS по документации загрязняет системный кеш после остановки Xray («нет сети»), а это ровно
  симптом, которого надо избежать. **документация** (https://xtls.github.io/en/config/fakedns.html).
- **Sniffing.** Перенести `sniffing` из inbound шаблона на наш TUN-inbound (не придумывать свой).
  Без шаблонного — `{enabled:true, destOverride:[http,tls,quic], routeOnly:true}`, помечать
  «добавлено KillSwitch» (как ADR 0013 для mihomo).
- **IPv6.** Как сейчас: в `autoSystemRoutingTable` только `0.0.0.0/0`, pf режет глобальный IPv6,
  в подписке `queryStrategy: UseIPv4`. FakeIPv6/IPv6 через туннель — отдельной задачей.
- **MTU.** 1500 (умолчание Xray). Под REALITY/xHTTP фрагментация не мешает; подбирать не надо.
- **Kill switch (pf), без изменения `rules()`:**
  - Xray запускается launchd с `GroupName _ksvpn` → его сокеты проходят к `servers`, а при
    непустом `egress` — куда угодно (ADR 0013).
  - `gateway: ["198.18.128.0/30"]` → utun `inet 198.18.128.1 --> 198.18.128.0`, т.е. адрес в
    198.18/16 и равен `CORE_TUN_ADDR`: `vpn_ifaces` пропускает его, `foreign_tuns` считает своим.
    **документация (исходник `selectDarwinGateway`/`setIPAddress`)**, проверить `ifconfig`.
  - Адреса серверов: хелпер, как для mihomo, заменяет доменный `address` outbound'а на IPv4
    (наш DoH через туннель) и, если нет `serverName`, ставит домен в `serverName`; IP идут в
    `servers`. `route-exclude-address` не нужен — его роль выполняет `autoOutboundsInterface`.
  - `egress` для Xray: `rules`, если какое-то правило/балансировщик ведёт в outbound
    `freedom` (кроме LAN-адресов); `dns`, если DNS-сервер подписки уходит через `freedom`
    (у владельца так: 77.88.8.8 → direct); `splitapps` — как сейчас. Эти цели входят в подпись
    `direct_sig` (смена требует пароль).
  - Фильтр контента: доверяет по подписи (`TrustedCode`), не по пути — см. §5.
  - На Маке владельца стоит LuLu с правилом на `/Library/KillSwitch/core/mihomo` (из памяти,
    сессия 10.10 на Pro) — новому бинарнику понадобится своё правило LuLu. **неизвестно**, как
    LuLu поведёт себя с root-процессом без правила (заблокирует молча?).

## 5. Подпись и нотаризация

- Ровно как mihomo: `codesign --force --sign "<Developer ID>" --identifier <id> --options runtime
  --timestamp`, без entitlements, внутри `Resources/Helper`, нотаризуется вместе с приложением.
  Go-бинарнику JIT/`allow-unsigned-executable-memory` не нужны (mihomo с теми же флагами работает —
  **измерено** на прошлых релизах; для Xray — **неизвестно**, проверить `xray version` после
  подписи; Lua `script` (#6823) — интерпретатор gopher-lua, JIT нет).
- Идентификатор: вариант 1 — тот же `com.lesha19.KillSwitch.core` (фильтр и `TrustedCode` не
  меняются, обновлять системное расширение не нужно; ядра не работают одновременно). Вариант 2 —
  `com.lesha19.KillSwitch.core.xray` + новый `TrustedCode.Program` + обновление фильтра
  (`FilterUpgrade`). Для первого среза — вариант 1; для режима «Xray за mihomo» (два процесса
  сразу) — вариант 2.
- `scripts/sign-core.sh` уже принимает путь бинарника; `release.sh` проверяет и копирует
  `mihomo geosite.dat geoip.metadb` — добавить `xray` и `geoip.dat`. Размер DMG +~20 МБ.
- Апстрим-бинарник не подписан Developer ID (ad-hoc) — **неизвестно**, проверить `codesign -dv`.

## 6. Рекомендуемая архитектура

### 6.1 Почему чистый Xray-TUN, а не «Xray за mihomo»

| | Чистый Xray-TUN | mihomo TUN → SOCKS → Xray (#10, режим A) |
|---|---|---|
| Совпадение с Happ | то же ядро и тот же конфиг подписки, тот же путь пакетов (gVisor TUN Xray) | маршрутизирует Xray, но DNS/TUN/sniff — mihomo; UDP/QUIC через SOCKS UDP-associate |
| Процессы | один | два (два launchd-задания, две подписи, синхронизация) |
| DNS | Xray `dns` подписки | fake-ip mihomo + `dns` Xray — два слоя |
| Список соединений, программы | нет API списка соединений; есть счётчики (stats API, unix-сокет), статус observatory | есть (mihomo) |
| Программы мимо VPN | правило `process` (macOS с v26.7.11) | как сейчас |
| Объём | меньше: один генератор | больше: генератор Xray + обвязка mihomo |

Владелец хочет «как Happ», а Happ — это именно Xray-TUN. Режим A оставляет mihomo в пути пакетов,
а именно mihomo сейчас «гасит интернет»; его причина не найдена, и режим A её не исключает.
Предложение: настройка «Ядро: Xray (как Happ) / Mihomo», режим A — позже и только если не хватит
списка соединений.

### 6.2 Как устроить

- **Настройка** `core=xray|mihomo` в `/Library/KillSwitch/settings` (`ks set core …`, пароль),
  UI: Настройки › VPN «Ядро». Смена: `ks core off` → генерация → `ks core on`; pf всё это время
  default-deny, утечки нет, есть только пауза в связи.
- **Хелпер (`Helper/ks`)**: `core_generate` раздваивается на `core_generate_mihomo` (как есть) и
  `core_generate_xray`. Xray-ветка берёт один конфиг из массива подписки (выбранный «сервер» =
  элемент массива по `remarks`) и:
  - выбрасывает `inbounds`, `api`, `stats`, `metrics`, `reverse`, `routing.script`,
    правила с `webhook`, `log` (ставит свой: `loglevel warning`, без access-лога),
    outbound'ы с `sendThrough`, `sockopt.interface`/`mark`; whitelist протоколов outbound'ов:
    vless, vmess, trojan, shadowsocks, hysteria2, wireguard, freedom, blackhole, dns, loopback
    (`dialerProxy`/`proxySettings` только на outbound'ы того же конфига);
  - пинит адреса серверов в IPv4, пишет `servers`, `egress`, `direct_sig`, `routing.json`
    (отчёт ADR 0013 по правилам Xray);
  - добавляет свои inbound'ы: `tun` (`name` не задаём, `gateway 198.18.128.0/30`,
    `autoSystemRoutingTable ["0.0.0.0/0"]`, `autoOutboundsInterface "auto"`, sniffing из
    шаблона), `ks-dns` (`tunnel` 127.0.0.1:53), `ks-fetch` (`http` 127.0.0.1:47890, ADR 0016:
    правило `inboundTag ks-fetch →` балансировщик/первый proxy, никогда freedom), `api` на
    unix-сокете `ctl/xray.sock` (commander умеет `UnixAddr` — **документация, исходник
    `app/commander`**) для трафика и observatory; свои правила — первыми;
  - пользовательское: «Программы без VPN» → правило `process` → `direct`; блок рекламы →
    `geosite:category-ads-all → block`; «Двойной VPN» → `proxySettings`. Всё помечено «добавлено
    KillSwitch»;
  - проверка `xray run -test -c` (как `mihomo -t`).
- **launchd**: тот же `local.killswitch.core`, программа выбирается при генерации (второй plist
  `local.killswitch.core.xray.plist` с `xray run -c /Library/KillSwitch/core/xray.json`,
  `XRAY_LOCATION_ASSET=/Library/KillSwitch/core`, `GroupName _ksvpn`) — включён ровно один.
- **`ks core proxies/select/delay/traffic/connections`** для Xray: `proxies` — список конфигов
  подписки + статус observatory; `select` — перегенерация с другим элементом массива; `delay` —
  observatory/`burstObservatory` подписки; `traffic` — StatsService; `connections` — «недоступно
  в Xray» в окне «Трафик».
- **Приложение**: `SubscriptionHeaders` — UA по ядру (для Xray: путь `/json` или UA из
  JSON-fallback списка; StorkVPN-овский Caddy фильтрует UA — **неизвестно**, что пропустит
  `Happ/…` от не-Happ); `ProfileConverter` → новый `XrayProfile` (разбор массива, имена, без
  секретов в логах); `ServersScreen`, `TrafficView`, `DiagnosticsCopy` (версия ядра),
  `HelperCommand` (`setCore`), `SettingsView`.
- **Файлы**: `Helper/fetch-xray.sh` (новый, пин + sha256 zip + подпись), `Helper/fetch-geodata.sh`
  (+`geoip.dat`), `scripts/sign-core.sh` (без изменений или identifier параметром),
  `scripts/release.sh`, `Helper/install.sh` (`core_update` для второго бинарника и plist),
  `Helper/uninstall.sh`, `Helper/ks`, `Helper/tests/*` (новые `core-xray-*.sh` + фикстуры из
  шаблона владельца без секретов), `App/Core/*` как выше, ADR 0017 «ядро Xray».
- **Миграция**: по умолчанию после обновления остаётся `mihomo`; Xray включается в настройках;
  после проверки владельцем — сделать Xray умолчанием для новых установок. Откат — переключатель
  обратно, оба бинарника в пакете.

### 6.3 Оценка

| Этап | Содержание | Дни |
|---|---|---|
| 1. Первый срез (ниже) | Xray-TUN с pf, один сервер из подписки, ручной запуск через `ks` | 3–5 |
| 2. Импорт подписки | разбор массива, whitelist, пины, egress/direct_sig, отчёт, тесты | 5–7 |
| 3. Настройка ядра и UI | `core=`, выбор сервера, трафик/observatory, программы мимо VPN, реклама, двойной VPN | 4–6 |
| 4. Обкатка | обновление Sparkle с работающим Xray, сон/пробуждение, смена сети, неделя на Air/Pro | 3–5 |
| Итого | | **15–23** |
| (опц.) режим A | Xray за mihomo | +5–7 |

### 6.4 Риски

| Риск | Что делать |
|---|---|
| Xray-TUN на macOS молодой (с января 2026, маршруты с июня) | пин версии, тест сна/смены Wi‑Fi, режим mihomo как запасной |
| Всё prerelease, ключи меняются | пин + `xray run -test` в генераторе и в тестах; обновлять только с приложением |
| Подписка = полный конфиг (webhook, script, api, reverse) | жёсткий whitelist, вырезать, отказ импорта при неизвестном |
| Маршруты после `kill -9`/краша | watchdog (`tun_guard`) проверяет и чистит `1/8…128/1` на чужой/мёртвый utun; pf всё равно режет |
| DNS-утечка мимо 127.0.0.1 (scoped-запросы macOS на интерфейс) | pf их режет (как сейчас); проверить `LeakTester` |
| LuLu/фильтр не узнают новый бинарник | тот же identifier; правило LuLu владельцу |
| Нет списка соединений | честно сказать в окне; режим A — если станет нужно |
| UA/Caddy панели режет запрос JSON | путь `/json` или правило SRR на панели (решение владельца) |

## 7. Первый срез (вертикальный, проверяемый)

Цель: на Маке владельца Xray v26.9.30 держит туннель по его Литве при включённом kill switch,
сайты открываются, BY/RU — как велит шаблон, ничего не утекает.

1. `Helper/fetch-xray.sh`: скачать `Xray-macos-arm64-v8a.zip` пина, сверить sha256, распаковать
   `xray`, подписать `scripts/sign-core.sh Helper/xray` (identifier `com.lesha19.KillSwitch.core`),
   `xray version`. `fetch-geodata.sh` + `geoip.dat` (пин).
2. `ks core_generate_xray <config.json>`: один элемент массива подписки → свой `xray.json`:
   вырезать inbounds/api/…; tun + ks-dns + ks-fetch; пины → `servers`; `egress` (rules/dns);
   `xray run -test`.
3. `local.killswitch.core.xray.plist` (root, `_ksvpn`, `XRAY_LOCATION_ASSET`); `ks core on` при
   `core=xray` грузит его вместо mihomo; `dns_apply` как есть.
4. Проверки (критерий готовности):
   - `ifconfig` — utun с `198.18.128.1 --> 198.18.128.0`; `netstat -rn` — `1/8 … 128/1` на него;
   - `pfctl -a <anchor> -s rules` — без изменений; `ks status` видит наш туннель, `foreign-vpn` пуст;
   - `curl https://ifconfig.me` → литовский IP; `yandex.ru`/`bsu.by` → по шаблону (direct — IP
     провайдера); `LeakTester`/`Helper/tests/rules.sh` зелёные;
   - `xray` выключить (`launchctl kill KILL`) — интернета нет, маршруты не мешают поднять снова;
   - тест в `Helper/tests/core-xray.sh` на генератор (фикстура из шаблона без секретов).

UI в первом срезе — нет (переключение через `ks set core xray`).

## 8. Вопросы владельцу

1. Чистый Xray-TUN основным режимом вместо «Xray за mihomo» (#10/#31)? Цена — нет списка
   соединений в «Трафике».
2. Какой UA/путь пропускает панель (Caddy StorkVPN/своя Литва): `/api/sub/<id>/json` открыт? Можно
   ли добавить правило SRR для UA `KillSwitch-Xray/…` → `XRAY_JSON`?
3. Добавить в шаблон панели `geoip:by`, `domain:by`, `domain:бел` в direct (правила только из
   подписки, ADR 0013)?
4. Пин: v26.9.30 сейчас или ждать неделю на v26.10.10?
5. Тот же identifier подписи для xray (без обновления фильтра) — ок?
6. Причина «пропадает интернет» на mihomo не найдена — до перехода стоит собрать
   `ks status`, `core.log`, `netstat -rn` в момент сбоя, чтобы не перенести её в Xray (pf, DNS 127.0.0.1
   и watchdog общие для обоих ядер).

## Источники

- Xray-core: https://github.com/XTLS/Xray-core/releases (API), `proxy/tun/README.md`,
  `proxy/tun/tun_darwin.go`, `proxy/tun/handler.go`, `proxy/tun/config.proto`, `infra/conf/tun.go`,
  `infra/conf/xray.go`, `infra/conf/router.go`, `app/commander/commander.go`,
  `common/net/find_process_darwin.go` (тег v26.10.10); PR #5559, #6366, #6434, #6447, #6557, #6580.
- Xray docs: https://xtls.github.io/en/config/fakedns.html
- Remnawave backend 3.4.5: https://github.com/remnawave/backend/tree/3.4.5 (файлы в §3);
  шаблоны https://docs.rw/learn-en/templates (не открылась 10.10, ECONNRESET).
- Geodata: https://github.com/MetaCubeX/meta-rules-dat , https://github.com/Loyalsoldier/v2ray-rules-dat ,
  https://github.com/runetfreedom/russia-v2ray-rules-dat
- Happ: бинарник `/Applications/Happ.app` 6.0.0 на этом Маке (entitlements, `go version -m`, strings);
  обзоры https://www.securitylab.ru/blog/personal/Bitshield/361724.php (внутренности не описаны).
- Локально: `Helper/ks` (`rules`, `vpn_ifaces`, `foreign_tuns`, `core_generate`, `CORE_TUN_ADDR`),
  `Helper/install.sh`, `Helper/fetch-mihomo.sh`, `Helper/fetch-geodata.sh`, `scripts/sign-core.sh`,
  `scripts/release.sh`, `Filter/TrustedCode.swift`, `App/Core/SubscriptionHeaders.swift`,
  ADR 0013, 0014, 0016.
