# atmospheric_snow / NewYear Interface: спецификация нативного iOS-порта

**Результат инспекции:** в полном исходнике найдены **15 пользовательских ключей и 1 служебный ключ миграции**. Отдельных настроек `intensity`, стиля стекла или стиля профиля нет: оформление использует общий `navbar_style`, `navbar_garland_palette` и частично `navbar_active_glow`. Нельзя ограничиться параметрами падающего снега.

Источник: `/data/data/com.termux/files/home/downloads/atmospheric_snow.plugin`, 4237 строк. Ниже **`S:Lx–Ly` означает точный якорь `atmospheric_snow.plugin:Lx–Ly`**; это локальный исходник, не файл в целевом GitHub-репозитории. SHA256 **предоставлен родительской сессией**, здесь не пересчитывался: `bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763`.

Цель по контексту родителя: `Nomadvorga/ayugram-ios`, ветка `plugins-test`, фиксированный commit `cc246f35559093e7bd645be367fb68f96b5b58f5`. На этом pin есть экспериментальный `AyuPluginBridge`, **модуля SnowEffect нет**. В этой задаче выполняется только статическая инспекция и запись отчёта: **не создаётся/интегрируется/компилируется нативный модуль, не меняются BUILD, manager или app integration, не подтверждается внешний вид или анимация**. Исходный пользовательский `.plugin` не должен публиковаться или коммититься.

## 1. Каталог настроек — использовать до реализации renderer

Машиночитаемая полная версия: **`atmospheric-settings.json` рядом с отчётом**. Имена ключей и `_cfg_*` ниже точно соответствуют исходнику. Все селекторы хранят **индекс**, а не физическое значение. Синхронизация и валидация: **S:L1053–L1082**; UI: **S:L4088–L4237**.

### 1.1. Boolean: все пять значений по умолчанию `true`

| Ключ | UI / кэш | Реальная область действия | SOURCE |
|---|---|---|---|
| `snow_enabled` | «Включить снег» / `_cfg_snow_enabled` | Только падающий снег. Резервная отрисовка профиля вызывается **до** проверки этого флага. | S:L1058; L1163–L1175; L4091–L4097 |
| `navbar_festive_enabled` | «Нижняя панель» / `_cfg_navbar_enabled` | Только `MainTabsLayout`: wash, декор панели и выбранной вкладки. | S:L1060; L2249–L2353; L4107–L4113 |
| `glass_pills_enabled` | «Кнопки, папки, ввод и шапка» / `_cfg_glass_enabled` | Общие blurred drawables, ActionBar, папки/фильтры, поиск, вкладки профиля, ввод чата. **Не** выключает profile actions/avatar/cards. | S:L1061; L2643–L2652; L2978–L2982; L4114–L4120 |
| `profile_festive_enabled` | «Профиль: кнопки, аватар и окна» / `_cfg_profile_enabled` | Крупные actions, круглый avatar, секционные cards и avatar backup. | S:L1062; L1163–L1168; L2978–L2982; L4121–L4127 |
| `navbar_active_glow` | «Сияние и морозные искры» / `_cfg_glow_on` | Fill/rim/две искры выбранной нижней вкладки; дополнительные искры обычных, **не thin**, glass pills; влияет на scheduling. **Не** отключает искры style 3 и базовое кольцо аватара. | S:L1065; L1780–L1785; L2277–L2286; L2335–L2351; L2884–L2886; L4147–L4153 |

### 1.2. Integer selectors: значения, диапазоны, defaults

| Ключ / кэш | Default; допустимые индексы | Индекс → UI и значение | SOURCE |
|---|---|---|---|
| `snow_area` / `_cfg_snow_area` | `0`; `0…2` | `0` «Везде»; `1` «Только в чатах» → simple name `ChatActivity`; `2` «Список чатов и чаты» → `ChatActivity` или `DialogsActivity`. Ограничивает только снег. | S:L1059; L1092–L1114; L4098–L4104 |
| `navbar_style` / `_cfg_navbar_style` | `0`; `0…3` | `0` «Снежная шапка + гирлянда»; `1` «Морозная (лёд и сосульки)»; `2` «Тёплая гирлянда»; `3` «Северное сияние и искры». **Общий** стиль navbar, glass и profile, не стиль снежинок. | S:L1063; L1658–L1785; L2040–L2135; L2862; L4128–L4139 |
| `navbar_garland_palette` / `_cfg_palette_idx` | `0`; `0…2` | `0` «Новогоднее ассорти»; `1` «Тёплое золото»; `2` «Ледяной неон». Реально используется лампочками styles `0`/`2`. | S:L45–L52; L1064; L1787–L1850; L4140–L4146 |
| `snow_density` / `_cfg_density_idx` | `1`; `0…2` | «Лёгкий», «Средний», «Сильный» → `26`, `50`, `82` частиц. Не нормируется по площади. | S:L26; L1066; L1116–L1122; L1226–L1240; L4156–L4162 |
| `snow_speed` / `_cfg_speed_idx` | `1`; `0…2` | «Медленно», «Обычно», «Быстро» → множитель **вертикальной** скорости `0.6`, `1.0`, `1.55`. | S:L27; L1067; L1295–L1298; L4163–L4169 |
| `snow_wind` / `_cfg_wind_idx` | `1`; `0…2` | «Штиль», «Лёгкий бриз», «Метель» → базовая скорость ветра `0`, `18`, `48` dp/s до gust и layer factor. Даже в штиль есть sway. | S:L28; L1068; L1228; L1244–L1246; L1288–L1296; L4170–L4176 |
| `snow_style` / `_cfg_snow_style` | `2`; `0…2` | `0` «Боке (мягкое свечение)»: layer 0 grain, layers 1/2 bokeh; `1` «Снежинки»: layer 0 grain, layers 1/2 crystals; `2` «Смешанный»: `is_crystal` → crystal, остальные **grain, не bokeh**. | S:L1069; L1267; L1327–L1340; L4179–L4185 |
| `snow_size` / `_cfg_snow_size` | `0`; `0…4` | «Очень мелкий (45%)», «Мелкий (70%)», «Обычный (100%)», «Крупный (135%)», «Очень крупный (175%)» → `0.45`, `0.70`, `1.0`, `1.35`, `1.75`. Только drawing radius, не физика. | S:L29; L1070; L1332–L1369; L4186–L4198 |
| `snow_opacity` / `_cfg_snow_opacity` | `4`; `0…4` | «Едва заметный (25%)», «Полупрозрачный (50%)», «Мягкий (75%)», «Обычный (100%)», «Яркий (135%)» → `0.25`, `0.50`, `0.75`, `1.0`, `1.35`. Это множитель alpha/яркости, **не** инвертированная прозрачность. | S:L30; L1071; L1313–L1325; L4199–L4211 |
| `snow_color` / `_cfg_snow_color` | `0`; `0…3` | `0` «Авто (по теме)»; `1` «Белый»; `2` «Ледяной голубой»; `3` «Тёплый новогодний». Только tint падающего снега. | S:L34–L42; L1072; L1124–L1139; L1248–L1257; L4212–L4223 |

**RGB снега** (S:L34–L42): auto dark `(240,247,255)`, auto light `(118,165,214)`; white `(255,255,255)`; ice blue `(188,226,255)`; warm `(255,241,204)`.

**Палитры гирлянд, циклические, без рандомизации цвета** (S:L45–L52; L1823–L1848):

| Индекс | RGB по порядку |
|---|---|
| `0` | `(255,208,88)`, `(255,86,98)`, `(82,232,152)`, `(110,204,255)` |
| `1` | `(255,214,102)`, `(255,236,168)`, `(255,184,78)` |
| `2` | `(128,214,255)`, `(235,248,255)`, `(98,238,224)` |

Style `2` **не принудительно выбирает золотую палитру**. Style `3` — rim и пульсирующие искры, а не движущиеся полотна северного сияния. Нет общего master switch для всех эффектов. Нет отдельного численного `intensity`: интенсивность снега задают count/opacity; интенсивность glass/profile вычисляется из **живых alpha, expansion, clipping и scale**, описанных далее.

### 1.3. Полный snapshot defaults после успешной migration v1

```json
{
  "snow_enabled": true,
  "snow_area": 0,
  "navbar_festive_enabled": true,
  "glass_pills_enabled": true,
  "profile_festive_enabled": true,
  "navbar_style": 0,
  "navbar_garland_palette": 0,
  "navbar_active_glow": true,
  "snow_density": 1,
  "snow_speed": 1,
  "snow_wind": 1,
  "snow_style": 2,
  "snow_size": 0,
  "snow_opacity": 4,
  "snow_color": 0,
  "snow_defaults_v": 1
}
```

**Default выглядит как 50 mixed частиц, обычная скорость, лёгкий бриз, 45% размера, 135% alpha, auto tint**, а не «обычный размер/обычная непрозрачность».

### 1.4. Валидация, обновление и миграция

- `_sync_settings_cache(force=False)` перечитывает **все 15** ключей не чаще чем раз в `0.40 s`; `force=True` обходится без ожидания. `_get_int_setting` делает `int(value)`, при `TypeError`/`ValueError` или индексе `<0`/`>=max_len` возвращает **default конкретного ключа**, не ближайшую границу. Для bool используется Python `bool(value)`; строка `"false"` сама по себе не false. Native persistence должна быть strongly typed; не принимать произвольные строковые значения молча. **S:L1053–L1082**.
- UI вызывает `_on_setting_change` для всех switches и selectors, **кроме** `snow_speed`/`snow_wind`: forced sync + `_refresh_screen`. Эти два вызывают `_on_physics_change`: только forced sync. Кэши геометрии не очищаются целиком при каждом изменении: нужный вариант выбирается по cache key. **S:L4081–L4086; L4091–L4223**.
- `_should_draw_now` для modes 1/2 кэширует результат выбора fragment на `0.25 s`; cache key **не содержит** `snow_area`, callback этот кэш не сбрасывает. После смены области возможен краткий старый результат. Mode 0 всегда true. Отсутствующий fragment для 1/2 даёт false, исключение — true. **S:L1092–L1114**.
- Служебный **`snow_defaults_v`**, read default `0`, не показан в UI. При load сначала `_ensure_default_snow_presets`: `int(get_setting(...,0) or 0)`, любое исключение → `0`. При `ver >= 1` не изменяет настройки; при `ver < 1` **перезаписывает даже уже существующие** семь snow selectors значениями `1,1,1,2,0,4,0`, затем пишет marker `1`. Marker идёт последним; при исключении операция может быть частичной и повториться на следующем load. Это **единственная миграция**, не версии `2`/`3`; plugin version `1.0.1` не равна версии migration. **S:L368–L370; L384–L401**.
- «Пресеты» в исходнике — наборы значений отдельных селекторов и одноразовый default preset migration, **не** несколько именованных full-theme presets и не UI-кнопки их применения. **S:L25–L52; L384–L401; L4088–L4237**.

### 1.5. Reset / clear settings: не приписывать исходнику отсутствующую кнопку

**В `create_settings` нет reset/clear/export/import settings actions.** Все `clear()` в lifecycle касаются runtime collections/cache; `Snowflake.reset` — respawn частицы. `on_plugin_unload` не удаляет сохранённые настройки. Поведение возможного общего reset в стороннем SDK из этого файла неизвестно. **S:L89–L128; L403–L449; L4088–L4237**.

Если родительская задача добавляет нативные reset/clear, это **явное расширение host, не обнаруженная функция плагина**:

1. Reset: только 15 owned keys к defaults из каталога; marker оставить/записать `snow_defaults_v=1`; обновить typed snapshot и видимые overlays. Не выдавать «обычный размер/opacity» за defaults.
2. Clear: revoke/unload generation, удалить только namespace `atmospheric_snow`, не общие настройки Ayu. Удалённый marker означает повтор migration семи selectors на следующем **явном** load.
3. При обычном unload preferences сохраняются; удаляются ссылки, subscriptions, clocks, textures и generation-bound host attachments. Нативная очистка всех runtime ресурсов обязательна, даже если Android исходник пропускает некоторые динамически заведённые cache fields.

## 2. Основание инспекции и границы доказательств

- Полностью прочитаны ranges **1–1060, 1061–1860, 1861–2660, 2661–3460, 3461–4237** через `functions.read`; scoped grep использован только в этом файле для settings, lifecycle, hook inventory и profile fields. Нет выполнения/import исходника, shell/git/network, скачивания compiler/native tools, репозиторных правок, build или кадров.
- Metadata: `__id__="atmospheric_snow"`, `__name__="NewYear Interface"`, author `@coshize`, version `1.0.1`, icon `Snowflake/1`, app `>=12.10.6`, SDK `>=1.4.4.3`, category appearance. Это **Android Telegram plugin SDK**, не Swift module/API. **S:L14–L22**.
- Внешние зависимости: `android_utils` (`log`, `run_on_ui_thread`), `base_plugin` (`BasePlugin`, `MethodHook`), `client_utils.get_last_fragment`, `hook_utils.find_class`, Java bridge, `BulletinHelper`, `ui.settings` (`Divider`, `Header`, `Selector`, `Switch`, `Text`). Android graphics/reflection classes перечислены в inventory ниже. **S:L1–L12; L612–L789**.
- Указания по целевому repo переданы родителем: стандартный Swift style, публичные docs, сильные типы, subsystem notes рядом с кодом; reusable view **никогда не меняет собственный `frame`**. Для визуальной/анимационной готовности необходимы recorded frames. Здесь нельзя утверждать соответствие изображения или плавности.
- Bridge guidance родителя: экспериментальный `AyuPluginBridge`; import **никогда не выполняет пользовательский plugin**, нет auto Python execution на app startup; только explicit UIKit host adapters; неизвестный API — явная ошибка, не «успех без результата»; нет synchronous main→Python waits или per-frame JSON; revoke по plugin generation на unload. Детальные критерии native mapping и acceptance — в конце отчёта. BUILD + manager + typed host attachment вне разрешённых изменений.

## 3. Архитектура, hooks, draw order и lifecycle

### 3.1. Load/unload и общие часы

`AtmosphericSnowPlugin` хранит массив `_flakes`, float clocks/elapsed, theme/density, paint/bitmap objects, geometry caches, reflection fields, identity sets для предотвращения повторной отрисовки и references на последний root/navbar. Начальные `_density_px=2.5`, `_is_dark_theme=True`, `_elapsed=0.0`; после graphics init плотность берётся из positive `Resources.getSystem().getDisplayMetrics().density`, тема — `Theme.isCurrentThemeDark()`. **S:L207–L328; L769–L789; L1084–L1090**.

**Load order**: сброс errors/counters и большинства runtime caches → установить `_last_time`/`_clock_last_time` → migration v1 → forced settings sync → `_init_graphics()` → первый подходящий root hook → navbar hook → view hooks → generic blurred drawable hooks. Если root hook не найден, записывается error/log/bulletin; остальные hooks уже пытаются установить независимо. Refresh вызывается в успешной root-ветке. **S:L330–L382**.

**Unload order**: `unhook_method` для всех полученных handles (исключения игнорируются), очистить handles/flakes, recycle graphics, очистить большинство geometry/reflection/identity caches, refresh старой области, обнулить last root/navbar, выставить hook statuses «выгружен». Не удаляет preferences; не восстанавливает прежний `willNotDraw`. `_elapsed` в load/unload не присваивается заново. **S:L403–L449; L451–L501**.

**Clocks**:

- Root snow: после bounds/gates `dt=clamp(now-_last_time,0,0.05)`; `_render_snow_frame` отдельно продвигает **общий** `_elapsed` на `clamp(now-_clock_last_time,0,0.05)`. Через каждые 30 clock/frame-counter increments проверяется тема. **S:L1193–L1221**.
- Decorations: `_advance_shared_clock` прибавляет время только при разнице `>=0.004 s`, максимум `0.05 s`, увеличивает общий counter и также обновляет тему каждые 30 increments. Нельзя складывать отдельно полное время для каждого host/overlay за один display tick. **S:L1141–L1155**.
- Snow loop запрашивает `layout.postInvalidateDelayed(20)` не чаще `20 ms` (`_snow_next_inval`), только если прошёл snow gate. Отсутствие eligible snow draw не запускает этот loop; decorations имеют отдельные нерегулярные invalidation paths. **S:L1157–L1208**.
- Выключение snow или смена area не очищает `_flakes`. Возврат ограничивается max `dt=0.05`, а не полной накопленной паузой. Native host должен останавливать свою generation-bound animation subscription при detach/unload и не устраивать «догоняющий» скачок.

### 3.2. Полный inventory целевых классов/hooks

Итого **14 различных Android target class names**; первые два — альтернативы, а не два одновременных root overlays. Native counterparts ниже — **семантические host роли**, не утверждение о наличии Swift symbol с таким именем на pinned branch.

| Android target class (точное имя) | Method / hook и порядок | Feature gate / результат | SOURCE; native expectation |
|---|---|---|---|
| `org.telegram.ui.ActionBar.DrawerLayoutContainer` | `dispatchDraw`, **after**, `DispatchDrawHook` | Первый успешный root: profile backup, затем snow поверх всего содержимого. | S:L131–L143; L846–L866; L1157–L1208. Explicit app-content root overlay. |
| `org.telegram.ui.ActionBar.ActionBarLayout` | `dispatchDraw`, **after**, тот же hook | Fallback только если предыдущий класс не удалось hook. | S:L846–L866. Альтернативная root host role, без двойного snow. |
| `org.telegram.ui.MainTabsLayout` | `dispatchDraw`, **before и after**, `NavbarDispatchDrawHook` | `navbar_festive_enabled`; до детей wash/selected fill, после детей rim/cap/garland/icicles/sparkles и selected rim. | S:L146–L161; L868–L878; L2249–L2353. Два слоя нижней navigation pill. |
| `org.telegram.ui.ActionBar.ActionBar` | `dispatchDraw`, **after**, `ViewPillHook(...,"actionbar")` | `glass_pills_enabled`; отдельные main/back/menu backgrounds, без wash. | S:L176–L192; L885–L899; L3034–L3100. Explicit header/back/search/menu host geometry. |
| `org.telegram.ui.Components.FilterTabsView` | `dispatchDraw`, **after**, mode `filters` | `glass_pills_enabled`; background или fallback inset rect. | S:L885–L899; L3102–L3126. Folder/filter tabs pill. |
| `org.telegram.ui.Components.FragmentSearchField` | `dispatchDraw`, **after**, mode `search` | `glass_pills_enabled`; blur→bg→padding fallback только при существующем `bg`. | S:L885–L899; L3128–L3156. Search field host. |
| `org.telegram.ui.Components.chat.ChatInputViewsContainer` | `dispatchDraw`, **after**, mode `chatinput` | `glass_pills_enabled` + `drawInputBackground`; tall limit `520 dp`. | S:L885–L899; L3177–L3201. Chat composer container, не только однотипная 44pt pill. |
| `org.telegram.ui.Components.ViewPagerFixed$TabsView` | `drawChild(Canvas, View, long)`, **after**, `TabsDrawChildHook` | `glass_pills_enabled`; рисует **целый `thisObject` TabsView**, не child аргумент; global/per-view throttle. | S:L195–L204; L901–L941; L2972–L2997; L3158–L3175. Один overlay контейнера profile/media tabs. |
| `org.telegram.ui.Components.ProfileActionsView` | Первый successful из `onDraw`, `dispatchDraw`, `draw`; `ViewPillHook(...,"profile_actions")` | `profile_festive_enabled`; before увеличивает `_in_pa_depth`, after уменьшает и рисует individual action rects. | S:L182–L192; L943–L954; L3284–L3554. Typed profile action targets, не три захардкоженных кнопки. |
| `org.telegram.ui.ProfileActivity$AvatarImageView` | `onDraw`, **after**, mode `profile_avatar` | `profile_festive_enabled`; circular ring с expansion/story inset guards. | S:L956–L964; L3556–L3584. Profile avatar host. |
| `org.telegram.ui.Components.RecyclerListView` | `dispatchDraw`, **after**, mode `recycler` | `profile_festive_enabled`; только qualifying section list внутри active profile. | S:L966–L975; L3795–L4023. Profile grouped-section card host, не все списки. |
| `org.telegram.ui.Components.blur3.drawable.BlurredBackgroundDrawableRenderNode` | `draw`, **after**, `BlurredDrawHook` | `glass_pills_enabled`, размеры/alpha/ownership exclusions. | S:L164–L173; L1022–L1051; L2643–L2725. Existing glass-background target. |
| `org.telegram.ui.Components.blur3.drawable.BlurredBackgroundDrawableSource` | `draw`, **after**, тот же hook | Устанавливается независимо от других blurred target classes. | S:L1022–L1051; L2643–L2725. Та же семантическая native роль, не дополнительный слой за каждый Android backend. |
| `org.telegram.ui.Components.blur3.drawable.BlurredBackgroundDrawable` | `draw`, **after**, тот же hook | Устанавливается независимо; source/base inheritance может давать повторные Android callback paths. | S:L1022–L1051; L2643–L2725. Native ownership/dedup обязателен. |

`_try_hook_dispatch_draw` пробует exact declared method с class/argument candidates, затем declared-method scan по имени, затем `hook_all_methods`; `_try_hook_declared_draw` — exact method, scan по имени и одному parameter, затем all methods. Returns/handles сохраняются в `_hooks`; неизвестные/missing classes дают status/error, не свидетельствуют о доступности эффекта. **S:L794–L844; L983–L1020**.

**Не hooks, но runtime class dependencies / match rules**:

- Graphics: `android.graphics.Paint`, `Bitmap`, `Canvas`, `RadialGradient`, `Rect`, `RectF`, `Path`, `LinearGradient`, `LightingColorFilter`, `Paint$Style`, `Paint$Cap`, `Bitmap$Config`, `Shader$TileMode` (с альтернативами nested static fields), `ARGB_8888`, clamp gradients, round stroke caps. **S:L612–L674**.
- Environment/identity: `org.telegram.ui.ActionBar.Theme`, `java.lang.System`, `android.view.View`, `android.view.ViewGroup`, `android.content.res.Resources`, `java.lang.Long.TYPE`. **S:L769–L789; L902–L904**.
- Fragment simple names: `ChatActivity`, `DialogsActivity` для snow area; `ProfileActivity` для active profile. View classification backup знает `ProfileActionsView` и `AvatarImageView` по class или максимум трём superclass names. **S:L1092–L1114; L3586–L3636**.
- Section exclusions: substring `SharedMedia` в full class name; `ViewPagerFixed` в simple name; exact `ShadowSectionCell`, `HeaderCell`, `TextInfoPrivacyCell`, `DividerCell`, `TabsView`, `EmptyCell`. Это exclusions, **не новые target hooks**. **S:L3953–L3962**.

### 3.3. Draw order, dedup и видимость

- Root: `_last_layout` + settings sync → optional profile backup → snow gate/resources/area → bounds → snow. Backup не покрывается `snow_area`. **S:L1157–L1208**.
- Navbar pre записывает identity background даже при выключенном navbar; post рисует декор поверх детей. Generic glass пропускает navbar drawable, **если navbar hook status заканчивается `OK`**, независимо от enabled navbar flag. Поэтому выключенная navbar не должна неожиданно получить generic glass overlay. **S:L2152–L2178; L2249–L2255; L2655–L2661**.
- `_handled_bg_ids` отмечает backgrounds, обслуженные owner view hook, `_ignored_bg_ids` — navbar/profile-action exclusions. Во время ProfileActions draw generic hook пропускается по `_in_pa_depth`; callback типа `ProfileActionsView` тоже excluded. Sets ограничиваются по количеству и могут очищаться. Это не абсолютная гарантия отсутствия first-frame/backend дубля. **S:L182–L192; L2643–L2673; L2775–L2783; L3323–L3337**.
- Обычные view modes проверяют `visibility == 0` и view alpha `>0.05`; actions/avatar дополнительно attachment/shown/scale и родителей. Scheduler `_throttle_view_inval` отдельно требует visible, attached, shown. Root/nav draw handlers не имеют такой же полной explicit hierarchy gate. **S:L2931–L2967; L2969–L3029**.
- Existing canvas clipping принадлежит host. Передача `pill_path` меняет wash/rim shape, **но не превращает snow/wire/icicles в произвольный path-following renderer**. Нет универсального `clipPath` всех декоративных элементов; icicles/aura могут выходить за background bounds. **S:L1721–L1778; L2834–L2929**.

## 4. Снег: состояние частиц, динамика и реальные стили

### 4.1. State и распределение layers

`Snowflake.__slots__`: `x`, `y`, `layer`, `radius`, `speed_y`, `sway_amp`, `sway_freq`, `phase`, `phase2`, `alpha`, `angle`, `spin`, `twinkle_phase`, `twinkle_speed`, `variant`, `is_crystal`. **S:L66–L84**.

В следующей таблице длины/скорости/амплитуды умножаются на Android `_density_px`; angular frequencies/alpha — нет. Числа — диапазоны `random.uniform`/`randint`, не Swift defaults конкретной частицы.

| Layer / вероятность | Radius (dp) | speed_y (dp/s) | sway_amp (dp) | sway_freq | Alpha integer | `is_crystal` |
|---|---|---|---|---|---|---|
| `0`: roll `<0.48` → 48% | `2.2…4.0` | `20…36` | `5…11` | `0.6…1.2` | `85…145` | false |
| `1`: roll `<0.82` → 34% | `4.2…6.8` | `40…66` | `10…19` | `0.8…1.55` | `135…200` | отдельный 50% roll |
| `2`: остаток → 18% | `7.5…12.0` | `68…102` | `15…28` | `1.0…1.8` | `170…235` | true |

**SOURCE: S:L86–L128.** Начальный/recreated `x` — `[-28*dp, width+28*dp]`; при `random_y=True` `y=[0,height]`, иначе respawn `y=[-32*dp,-6*dp]`. `phase`, `phase2`, `twinkle_phase` — `[0,2π]`; `angle=[0,360]` degrees; `spin=[-38,38]` degrees/s; `twinkle_speed=[1.5,3.2]`; `variant=0…2` uniformly.

Массив не сортируется по layers перед drawing. «Передний/задний слой» здесь означает распределение размера/скорости/wind/alpha, а не гарантированный painter-order по depth. Mixed ожидаемо имеет около **35% crystals** (`0.34*0.5+0.18`); style 1 около **52% crystals**, а не все частицы снежинками. Это статистика генератора, не обещание точного количества в каждом frame.

### 4.2. Count, bounds reset, motion, wrapping

- Target count `DENSITY_COUNTS[index]`, всегда 26/50/82. Нет зависимости от bounds area. Если flakes отсутствуют **или** width/height изменились более чем на **80 raw Android pixels** относительно прошлого draw, массив полностью пересоздаётся с random y. Иначе дополнительные flakes создаются с random y, лишние удаляются с конца; прежнее состояние оставшихся сохраняется. **S:L1116–L1122; L1230–L1240**.
- `speed_mul` влияет только на `y`; `size_mul`/`opacity_mul` не меняют spawn, speed, sway или wind. `wind_base=WIND_STRENGTHS[index]*dp`. **S:L1223–L1228; L1295–L1298**.
- `_SIN_LUT` — 128 sample values одного периода, `_SIN_LUT_SCALE=128/(2π)`; lookup `sin_lut[int(angle*scale)&127]`, Python `int` truncates toward zero. Ветер gust использует обычный `math.sin`, sway/shimmer — LUT. **S:L31–L32; L1242–L1246; L1286–L1317**.

Точные формулы (`t=_elapsed`, `dt` в секундах, `dp=_density_px`; SOURCE **S:L1242–L1246; L1288–L1305**):

```text
wind_gust = wind_base * (0.65 + 0.35*sin(t*0.45) + 0.15*sin(t*1.15))
            if wind_base > 0 else 0
layer_wind = wind_gust * (0.42 + 0.34*layer)
sway = (lut(t*sway_freq + phase)
        + 0.42*lut(t*sway_freq*1.7 + phase2)) * sway_amp
y += speed_y * speed_mul * dt
x += (layer_wind + sway*0.45) * dt
angle = (angle + spin*dt) % 60, only when crystal sprite/style support exists
```

Margin `30*dp`: `y > height+margin` → полный `Snowflake.reset(...,random_y=False)`; иначе `x > width+margin` → `-margin`, `x < -margin` → `width+margin`. Size selector не меняет wrap margin. **S:L1261–L1262; L1300–L1305**.

### 4.3. Fade, shimmer, tint и selection sprite

Top fade первые `7%` height: при `0<y<0.07h` factor `y/(0.07h)`, при `y<=0` factor 0. Bottom fade после `0.88h`: `max(0,1-(y-0.88h)/(h-0.88h))`. Layer >0 shimmer `0.86+0.14*lut(t*twinkle_speed+twinkle_phase)` (range приблизительно `0.72…1.0`); layer0 не shimmer. Alpha `min(255,int(base_alpha*edge_factor*shimmer*opacity_mul))`, без shimmer для layer0; при `alpha<=3` не рисуется. **S:L1258–L1260; L1307–L1319**.

При восьми готовых Paint alpha используется **`[32,64,96,128,160,192,224,255][min(7,alpha>>5)]`**, а не точная вычисленная alpha; низкие положительные alpha 4…31 получают Paint alpha32. Если buckets недоступны, fallback Paint получает exact alpha. RGB меняет `LightingColorFilter(multiply RGB, add=0)`; white filter отсутствует. **S:L653–L657; L1124–L1139; L1248–L1257; L1321–L1325**.

| `snow_style` | Draw selection | Draw radius |
|---|---|---|
| `0` bokeh | layers ≥1 `_bmp_bokeh`; layer0 `_bmp_grain` | bokeh `radius*1.25*size_mul`; grain `radius*0.95*size_mul` |
| `1` crystals | layers ≥1 crystal независимо от `is_crystal`; layer0 grain | crystal `radius*1.35*size_mul`; grain `radius*0.95*size_mul` |
| `2` mixed | `is_crystal` → crystal; иначе grain; **нет bokeh** | crystal `radius*1.35*size_mul`; grain `radius*0.95*size_mul` |

Crystal выбирается по `variant` и rotation bucket `int(angle*0.1)%6` → `0°,10°,20°,30°,40°,50°`. Исходный шестилучевой crystal имеет symmetry60°. При отсутствии crystal cache соответствующие flakes переходят на non-crystal path. **S:L1264–L1271; L1327–L1340; L703–L722**.

Snow drawing в текущем файле идёт **на переданный canvas непосредственно**. `_snow_bmp`, `_snow_canvas`, `_snow_blit_paint`, `_snow_last_update` и некоторые соседние поля заведены, но `_render_snow_frame` не использует offscreen snow pipeline; нельзя предполагать отдельный blur/compositing snow layer из этих названий. **S:L250–L256; L658–L659; L1210–L1369**.

## 5. Sprite inventory: генерируемые assets и роли

Все sprites генерируются программно из белых Paint/gradients. Нет image file/network download в этом источнике; импортированное `__icon__` — metadata, не снеговая texture. Native mapping: generated/cacheable `CGImage`/native texture и геометрические paths, без исполнения Python или загрузки чужих assets.

| Asset | Размер Android bitmap | Содержимое / роль | SOURCE |
|---|---|---|---|
| `_bmp_bokeh` | `96×96` | Радиальный белый glow; snow layers≥1 в style0; также tinted aura fallback для лампочек и заготовка bulb sprite. Alpha/stops: `(255,0)`, `(230,.14)`, `(155,.30)`, `(78,.50)`, `(28,.70)`, `(7,.87)`, `(0,1)`. | S:L503–L523; L676–L688; L724–L746; L1827–L1848 |
| `_bmp_grain` | `64×64` | Плотная мягкая точка; layer0 всех snow styles, non-crystal flakes mixed. Alpha/stops `(255,0)`, `(245,.24)`, `(180,.44)`, `(72,.66)`, `(16,.84)`, `(0,1)`. | S:L690–L701; L1327–L1340 |
| `_bmp_crystals` | 3 штуки `128×128` | Шестилучевой snow crystal variants0/1/2: outer radial glow, широкая bloom stroke и тонкий bright core, branch arms, central hexagonal ring, center dot. | S:L525–L610; L703–L708 |
| `_bmp_crystals_rot` | `3×6` buckets `128×128` | Step0 — ссылка на base sprite; остальные sprites rotated10…50 degrees around `(64,64)`. Runtime drawing не вызывает rotate на каждом flake. | S:L709–L722; L1331–L1334 |
| `_bulb_sprites[rgb]` | по одному `64×64` на уникальный RGB всех palettes | Bokeh tint alpha185 + colored core alpha235 radius `half*.275` + white center alpha220 radius `core*.45`. Живые draw и baking используют эти sprites. | S:L724–L746; L1817–L1825; L2412–L2426; L2602–L2615 |
| `_bmp_sparkle` | `32×32` | Cross arms `size*.42`, diagonals55% длины; primary white alpha255, diagonals166, round cap, width `max(1,arm*.22)`. Draw size half=`requested_size*1.19`, tint and alpha. Если sprite не создан, drawLine fallback повторяет cross/diagonals. | S:L748–L767; L2199–L2223 |

**Crystal detail для точного procedural port** (S:L525–L610): arm length `size*.40`; glow alpha `[58,26,7,0]`, stops `[0,.35,.72,1]`; bloom alpha65/width`size*.062`, core alpha245/width`size*.025`; 6 arms с шагом π/3; hex ring radius `arm*.26`, для variant2 `arm*.34`; center white dot radius`size*.026`. Branch tuples = `(position_ratio,length_ratio,branch_angle_radians)`, каждый с двумя signs:

```text
variant 0: (.38,.24,.92), (.64,.21,.90), (.84,.11,.85)
variant 1: (.30,.16,1.00), (.50,.27,.92), (.70,.19,.88), (.87,.10,.82)
variant 2: (.44,.23,1.02), (.76,.18,.86)
```

**Quantization/caches, не дополнительный user setting**:

- Scaled snow diameter: `d_px=max(4,min(64,(int(r_draw*2+2)>>2)<<2))`, то есть 4-pixel buckets и hard cap64 **raw pixels**. Key `(id(source_bitmap),d_px)`; максимум96 entries, eviction самого раннего inserted entry; cache пересоздаётся при изменении size multiplier. Fallback — bitmap в exact `RectF`. **S:L1273–L1284; L1344–L1369**.
- `_tinted_paint` квантует alpha к `(alpha>>4)*16+15`, max255, cache `(rgb,level)`; при количестве>320 очищает cache. Sprite path может дать немного иную alpha, чем direct fallback. **S:L2180–L2197**.
- Live bulb sprite path использует `_tinted_paint(white,int(225*alpha_f))`, baking Paint alpha225; quantization live при `alpha_f=1` даёт239. Fallback bulbs рисуются отдельно: aura alpha`aura_alpha*.85*alpha_f`, core210, highlight195; wire alpha120 RGB`(62,92,118)` width default`.95dp`. `t` в `_draw_garland_bulbs` **не участвует в brightness**: гирлянды статичны, не мерцают. **S:L1787–L1850**.

## 6. Все festive styles, общая геометрия и navbar selection glow

### 6.1. Матрица styles: не додумывать поведение по названию

| `navbar_style` | Navbar / обычный rectangular glass pill | Profile actions/cards (`thin_decor=True`) | Круглый profile avatar |
|---|---|---|---|
| `0` cap + garland | Frost rim + snow cap/crest + wire + static colored bulbs; нет icicles. Navbar всегда имеет отдельный pre wash. | Та же комбинация в уменьшенном масштабе; без дополнительных glow sparkles. | Базовые cold halo/ring + upper arc + snow crescent + круговой wire/bulbs. |
| `1` frost | Frost rim + cap/crest + icicles и highlights; нет bulbs/wire. | Тонкий cap, укороченные icicles, rim; ограничения clipped top/bottom зависят от baked path. | Halo/ring + upper arc + snow crescent; **никаких сосулек у аватара**. |
| `2` warm garland | Wire + static bulbs; **нет frost rim/cap/icicles**. Navbar pre wash остаётся. Palette любая. | Только тонкие wire/bulbs. | Cold halo/ring остаются даже в warm style + circular wire/bulbs; upper arc/cap отсутствуют. |
| `3` aurora/sparkles | Frost rim + animated sparkles; **нет движущегося aurora field, cap, wire, bulbs или icicles**. Navbar wash остаётся. | Rim (в tall baked-strip path simplified) + style3 sparkles даже при glow switch false. | Halo/ring + upper arc + 4 animated sparkles; cap/bulbs отсутствуют. |

Дополнительные **обычные glass sparkles** присутствуют при `navbar_active_glow=true` и `not thin_decor` в styles0/1/2; style3 sparkles unconditional. Navbar `_draw_pill_festive_overlay` не включает отдельный generic `draw_sparkles`; его selected glow имеет собственные две искры. **SOURCE: S:L1658–L1785; L2040–L2135; L2321–L2351; L2884–L2924**.

### 6.2. Rounded pill geometry и адаптивные garlands

`_build_pill_geometry(pl,pt,pr,pb,...)` вычисляет `pw=max(10,pr-pl)`, `ph=max(10,pb-pt)`. Explicit `corner_rad` ограничивается `[0,min(pw/2,ph/2)]`; иначе radius `min(pw,ph)/2`, для non-navbar при `ph>58dp` ограничен24dp. `is_circle` — **heuristic** non-navbar, corner_rad absent, `pw<=ph*1.28`, `pw<110dp`; `is_compact` — non-navbar/non-circle `pw<145dp`. Это не та же геометрия, что отдельный avatar renderer. **S:L1382–L1407**.

| Геометрия | Snow steps; puff/thickness scale | Bulbs / core radius / aura radius | Wire: x inset ratio; sag; wire y / bulb y (dp) | Icicle positions и длины (dp) |
|---|---|---|---|---|
| Navbar | `44`; `1/1`; edge inset`.22` | `11`; `1.9/7.2dp` | `.36`; `2.3`; `.6/1.4` | positions `.04,.12,.21,.31,.40,.50,.60,.69,.78,.87,.96`; lengths `4.2,6.8,3.6,7.6,4.8,8.2,4.4,7.2,3.9,6.4,4.5`; inset`.65`, half-width base`1.35` |
| Circle heuristic | `24`; `.50/.58`; edge`.22` | `3`; `1.35/4.6dp` | `.30`; `1.0`; `.8/1.25` | positions`.28,.50,.72`; lengths`2.2,3.0,2.2`; inset`.62`, half-width base`.95` |
| Compact | `28`; `.65/.68`; edge`.24` | `max(3,min(5,floor(pw/dp/26)))`; `1.45/5.2dp` | `.34`; `1.45`; `.75/1.3` | positions`.14,.38,.62,.86`; lengths`2.6,3.9,3.2,2.7`; inset`.60`, half-width base`1.05` |
| Normal non-navbar | `40`; `.74/.74`; edge`.24` | `max(5,min(10,floor(pw/dp/36)+1))`; `1.50/5.4dp` | `.34`; `1.75`; `.75/1.35` | count`max(5,min(11,floor(pw/dp/24)))`; positions`(i+.5)/count`; repeated lengths`2.8,4.4,3.1,4.9,3.4,4.1`; inset`.65`, half-width base`1.10` |

**SOURCE: S:L1409–L1474.** В `thin_decor` non-navbar: puff scale×`.62`, thickness×`.56`, sag×`.72`, bulb y=`1.05dp`, core≤`1.30dp`, aura≤`4.35dp`, icicle lengths×`.76`. **S:L1476–L1483**.

Paths создаются по style: snow для `-1/0/1`, wire для `-1/0/2`, icicles для `-1/1`; **`-1` — внутренний build-all sentinel, не UI index**. `_pill_top_y` учитывает round corners через `sqrt(max(0,r²-dx²))`. **S:L1371–L1380; L1485–L1487**.

Snow cap top по `u=0…1`: `taper=sin(πu)^.55`, `puff=(.75+.55*sin(5πu+.4)+.30*cos(9πu))*dp*taper*puff_scale`; bottom thickness `(3.1+1.35*sin(6πu-.3)+.65*cos(11πu))*dp*taper*thick_scale`; top=`base_y-puff*.55`, bottom=`base_y+thick`. При clamp top минимальный top=`max(0,pt-.5dp)`. Замкнутый polygon + отдельная crest line. **S:L1489–L1523**.

Wire follows rounded top плюс `abs(sin(u*π*max(1,bulb_count-1)*.5))*sag`, wire/bulb y offsets. Wire samples54 при `pw>120dp`, иначе28; bulbs равномерны по u. Icicles начинаются у `pb-.8dp`, tip=`pb+length*dp`, half-width=`(base+length*.09)*dp`, боковые quadratic curves + внутренний highlight. **S:L1525–L1576**.

### 6.3. Frost gradients, sparkle positions

RGBA в таблице записаны `(alpha,R,G,B)`; native alpha нормируется к255, не трактуется как отдельная настройка.

| Material | Colors / координаты | SOURCE |
|---|---|---|
| Snow cap | `(242,255,255,255)` → `(215,232,245,255)` → `(145,185,218,250)`, stops`0,.58,1`, y`pt-1.8dp…pt+5.8dp*thick_scale`; crest white alpha190 width`.85dp`. | S:L1581–L1586; L1754–L1764 |
| Frost wash | RGB`(165,218,255)` с top alpha navbar dark/light`30/38`, other`22/30`; bottom transparent `(180,225,255)` к y`pt+ph*.65`. | S:L1587–L1597 |
| Frost rim | dark top`(145,210,236,255)` → bottom`(45,130,185,235)`; light top`(170,130,195,245)` → bottom`(60,100,165,225)`; вертикальный gradient pt→pb. | S:L1598–L1608 |
| Icicles | `(195,235,248,255)` → `(115,175,220,255)`, y`pb-dp…pb+(max_length+.5)dp`; highlight white alpha145 width`.70dp`. | S:L1609–L1614; L1742–L1752 |

Sparkle positions (**S:L1616–L1633**): circle heuristic — 2 на `(pr-.20pw,pt+.22ph)` size2.3dp и `(pl+.20pw,pb-.22ph)` size1.9dp; thin — 2 на верхних углах с inset`max(rad,12dp)*.65`, y`pt+6.5dp`, size2dp; normal/navbar — 3: верхние слева/справа inset`.62rad`, y7.5/8dp, и нижний center y`pb-4.2dp`/navbar`pb-5.5dp`; sizes normal2.2/2.2/2.1dp, navbar2.8/2.8/2.9dp.

Pill sparkles pulse `sp=.35+.65*(.5+.5*sin(t*2.5+idx*2.1))`; alpha base215 для style3, иначе155, RGB`(220,244,255)`, умножение на target `alpha_f`. **S:L1780–L1785**. Thin выключает только дополнительные glow sparkles, **не** style3 sparkles.

### 6.4. Navbar: selection glow и слои

Bounds guard `w/h>20` **raw pixels**. Pill inset `7.67dp` со всех сторон; `pr=max(pl+40,w-pad)`, `pb=max(pt+20,h-pad)` (40/20 — raw pixels). Геометрия кэшируется по integer width/height/theme; builder navbar создаёт paths для всех styles. **S:L2137–L2150; L2259–L2262; L2297–L2300**.

Selected rect — первый visible immediate child с `isTabSelected()==true`, bounds плюс `translationX/Y`, не reflection field с индексом selection. Если такого child нет, selected glow отсутствует; общий декор navbar остаётся. **S:L2225–L2247**.

**До children** (`_on_navbar_before_draw`, S:L2249–L2286):

1. Frost wash внутри rounded navbar pill **для любого style**, с полной target alpha1.
2. Если glow switch true и есть selected rect: fill RGB`(130,210,255)`, radius половина min selected width/height; `pulse=.72+.28*sin(_elapsed*2.3)`; alpha `int((dark?34:42)*pulse)`. Before handler сам часы не продвигает.

**После children** (`_on_navbar_after_draw`, S:L2288–L2353):

1. Advance shared clock; style-dependent festive overlay alpha1, rim width1.15dp, `draw_wash=False`, `draw_sparkles=False`.
2. При glow switch true: selected rect inset`.6dp`; rim RGB`(175,226,255)`, width1.05dp, alpha`int(115*(.65+.35*sin(t*2.3)))`.
3. Две искры: верхняя справа `(tr-7dp,tt+7dp)`, size3dp, RGB`(235,248,255)`, alpha210×`(.45+.55*(.5+.5*sin(t*3.1)))`; нижняя слева `(tl+8dp,tb-7dp)`, size2.2dp, RGB`(255,232,170)`, alpha170×`(.45+.55*(.5+.5*sin(t*2.7+1.9)))`.
4. Throttle invalidation минимум`.080 s`, но helper делает request только при style3 **или** glow true и visible/attached/shown.

Native mapping должен сохранять pre-content fill и post-content outline, selected-target geometry/translations и общие часы. Нельзя заменить это одной одноцветной подложкой выбранной вкладки или анимировать статичные bulbs.

## 7. Glass pills: dynamic config, exceptions и owner-specific paths

### 7.1. Общий drawable hook

`_on_glass_pill_after_draw` не рисует при null canvas/drawable, `_in_pa_depth>0`, выключенном glass, неготовой graphics, уже handled/ignored identity. При working navbar hook исключает navbar background; при callback `ProfileActionsView` исключает profile action drawable. Alpha `getAlpha()` default255, `<=5` skip. Bounds preferred `getPaddedBounds()`, иначе `getBounds()`. Filter размеров **`pw>=24dp`, `ph>=22dp`, `ph<=88dp`, `pw<=650dp`**. Optional nonempty `getPath()` передаётся дальше; target alpha=`clamp(alpha/255,0,1)`, `draw_wash=True`. **S:L2643–L2716**.

Generic invalidation request только при **style3**, drawable alpha>12 и callback instance of View, minimum interval`.095 s`. Glow switch true сам по себе не заставляет этот generic hook анимировать extra sparkles в styles0/1/2. **S:L2718–L2725**.

Этот plugin **не создаёт сам blur/background стекла**: существующий Android drawable уже отрисован, плагин добавляет wash/rim/cap/garland. Native host должен предоставлять существующий UIKit glass/blur target и его geometry; «заменить весь экран blur effect» — другая функция.

### 7.2. Общий `_draw_glass_pill_rect` contract

- Defaults: `draw_wash=False`, `max_ph_dp=88`, `corner_rad=None`, `thin_decor=False`, `rim_width_dp=1.05`, `clamp_top_edge=None`, `draw_top=True`, `draw_bot=True`. Guard target alpha`.02`, minimum24×22dp, height≤caller max, width≤**1200dp**. Generic hook имеет **более узкий** width cap650dp. **S:L2834–L2859**.
- `clamp_top` — explicit caller flag, иначе `pt<=1.8dp`. Style/palette — **общие navbar settings**, не стеклянные private defaults. Extra sparkles=`_cfg_glow_on and not thin_decor`; часы продвигаются при style3 или extra sparkles. **S:L2861–L2886**.
- Для thin без `pill_path`, height≤120dp: cached width округлён к8 **raw pixels**, height к4 raw pixels (`max(24,round(pw*.125)*8)`, `max(22,round(ph*.25)*4)`), drawing масштабируется обратно `pw/q_pw`, `ph/q_ph`. Geometry quantization — runtime optimization, не отдельный setting. **S:L2867–L2871; L2901–L2908**.
- Optional pill path локализуется offset`(-pl,-pt)`; для origin0 используется напрямую. Path запрещает bitmap baking (`allow_bake=False`); wash/rim используют path, остальные decorative paths — round-rect-derived geometry. Canvas save/translate/scale/restore, не mutation frame/view. **S:L2872–L2882; L2888–L2929**.
- Flags `draw_top/draw_bot` реально проверяются в baked **strip** branch; unbaked/full static-bitmap branch не фильтрует top/bottom отдельно. Это source limitation, не доказательство корректного clipping для всех состояний. **S:L1685–L1764**.

### 7.3. Полный набор динамических owner configs

| Mode | Exact fields/defaults и выбор target | Wash / размерные исключения / scheduling | SOURCE |
|---|---|---|---|
| `actionbar` | `glassOnlyBack=False`, `doNotDrawGlassMenu=False`, `backButtonImageView=None`; main `glassDrawable` если not glassOnlyBack; back `glassDrawableBack` если back visible; menu `glassDrawableMenu` если neither suppression flag. Если candidates пусты: scan superclass fields до `FrameLayout`/`ViewGroup`/`View`/`Object`, value simple name содержит `Blurred` или `GlassDrawable`. | Для каждого candidate отметить handled identity; alpha drawable×view alpha; `draw_wash=False`, common88dp/1200dp caps. При successful draw interval`.140s` (helper gated style3/glow). | S:L3034–L3100 |
| `filters` | `getBackground()`, иначе field `blurredBackgroundDrawable`. Только когда drawable **отсутствует**, fallback inset9dp rect при width>`2pad+40dp`, inner height22…88dp. Невалидный non-null drawable не включает fallback. | Handled identity; alpha drawable×view alpha, no wash; `.140s` scheduling. | S:L3102–L3126 |
| `search` | Field `blurredBackgroundDrawable`, затем `bg` если blur не дал draw. Padding rect fallback только если `bg` существует, но `_extract_drawable_info(bg)` не дал info. Когда обе backgrounds absent — нет generic rect fallback. | Blur помечается handled, `bg` в этой ветке не помечается. No wash; `.140s` scheduling **только style3**, не glow-only. | S:L3128–L3156 |
| `tabs` | Background, иначе `blurredBackgroundDrawable`; никакого whole-view fallback при отсутствии обоих. `drawChild` after handler uses TabsView `thisObject`; global suppression `<.008s` и per-id suppression `<.005s`. | Handled identity; alpha drawable×view alpha, no wash; `.140s` scheduling **только style3**. Native рисует один container overlay, не duplicate за каждого child. | S:L195–L204; L2972–L2997; L3158–L3175 |
| `chatinput` | Field `drawInputBackground=True`; false полностью suppress. Только `blurredBackgroundDrawable`, не width/padding fallback. | Handled identity; no wash; **height cap520dp**; common width1200dp. `.050s` scheduling **только style3**. Tall/path-bearing input не должен насильно превращаться в маленькую pill. | S:L3177–L3201 |
| `profile_actions` | Отдельный typed action rect contract, hierarchy + header + expansion + background guards, §8. | **Profile**, а не glass flag. No wash, thin, height cap120dp, actual corner radius, rim1.15dp. | S:L2978–L3002; L3203–L3207; L3284–L3554 |
| `profile_avatar` | Expansion/story/foreground contract, §8. | Profile flag; отдельный circle renderer, не glass pill; `.140s` scheduling только style3. | S:L3008–L3025; L3209–L3215; L3556–L3584 |
| `recycler` | Profile section ownership/group contract, §9. | Profile flag; no wash, thin, height cap1800dp, section radius, rim1.20dp; нет собственного periodic invalidation. | S:L3217–L3219; L3795–L4023 |

`_extract_drawable_info` имеет те же alpha/default255/<=5 и padded→bounds правила, но проверяет nonempty bounds; `_gd_has_padded` определяется один раз через `hasattr` и затем используется глобально, не per drawable class. Reflection `_get_field_val` кэширует доступный field или sentinel `False` по class identity/name, ищет до superclasses, default на lookup/get failure. **S:L2727–L2773; L2785–L2832**. В native mapping это должны быть typed host properties, а не перенос универсального reflection/silent-success паттерна в bridge.

## 8. Профиль: avatars, action buttons и ограниченный backup

### 8.1. Profile avatar: все динамические поля и fade

Owner gate: видим, attached, shown; self/первые два View parents имеют scaleX/Y>`.15`; parent alpha>`.05`; effective alpha self×двух parents, final>`.05`. При exception Android guard fallback alpha1. **S:L2999–L3029**.

Size из width/height, при nonpositive — measured width/height. Требуется **w/h≥38dp**, `abs(w-h)<=12dp`; ring helper требует outer radius≥18dp и alpha>.04. Fields/defaults:

```text
progressToExpand = 0.0
hasStories = False
progressToInsets = 1.0
foregroundAlpha = 0.0
```

При `progressToExpand>=.55` overlay отсутствует. `fade=clamp((.55-progressToExpand)/.35,0,1)*view_alpha`: полный до progress`.20`, исчезает на`.55`. Story inset = `(int(3.5*dp) if hasStories else 0)*(1-progressToExpand)*progressToInsets*(1-foregroundAlpha)`. Эти четыре runtime inputs нужны даже при абсолютно правильном settings snapshot. **S:L3556–L3584**.

Geometry нормализуется к reference square `ref_s=max(48,round(96*dp))` raw pixels, scale=`min(w,h)/ref_s`; inset также приводится к reference и округляется; transform центрирует square в actual w/h. Cache key содержит rounded reference width/height/inset, theme, style и palette для styles0/2. **S:L1852–L1859; L2040–L2065**.

**Кольцо и decorations** (S:L1934–L2038; L2078–L2130):

- `outer_r=min(w,h)/2-inset`, `rim_r=max(12dp,outer_r-1.35dp)` на reference geometry. Во **всех styles** soft ring alpha85 RGB`(170,224,255)` width3.4dp + gradient ring top `(235,224,244,255)` → bottom `(120,145,206,250)`, width1.65dp.
- Styles0/1/3: inner upper arc radius`rim_r-1.2dp`, start`-162°`, span144°, alpha175 RGB`(245,252,255)`, width`.9dp`.
- Styles0/1: снежный crescent по angles`-142°…-38°`, 28 segments, outer radius`outer_r-.5dp`, inward thickness`(2.1+.85*sin(5πu+.3))*dp*sin(πu)^.55`; inner radius minimum8dp; gradient alpha245 white →175 RGB`(214,238,255)`, crest white alpha195 width`.75dp`. **У аватара нет pill icicles**.
- Styles0/2: closed circular wire, **14 bulbs если reference outer_r≥44dp, иначе10**, wire radius`rim_r-2.3dp`, radial sag `abs(sin(u*π*bulb_count))*1.25dp`, samples5×bulbcount. Bulbs at `(i+.5)/count` и radius`wire_r-1.25dp-.55dp`; aura4.2dp, core1.25dp, wire`.85dp`, fallback aura alpha180. Static, не blink.
- Style3: четыре sparkles на angles`-138°,-42°,48°,138°`, radius`rim_r-1.6dp`, sizes`2.3,2.3,2.1,2.1dp`; тот же pulse `sin(t*2.5+idx*2.1)` с angular speed **2.5 rad/s, не 2.5 Hz**, base alpha225, RGB`(225,246,255)`. Glow switch это не отключает.

Статический bitmap ring/cap/wire/bulbs может быть baked после третьего hit; style3 sparkles рисуются отдельно. `canvas.save/translate/scale/restore` сохраняет layout владельца; reusable native view рисует в `bounds`, host передаёт dimensions/inset/progress, view не меняет own frame.

### 8.2. Profile action buttons: UI говорит «3», code итерирует все actions

Mode `profile_actions` проверяет `_check_pa_hierarchy_visible`: attached/visibility/shown, self alpha>.05, self scales>.15, multiplies alpha и checks scales для максимум двух parents; исключение →1. **S:L2948–L2967**. `_draw_profile_actions_view` дополнительно:

1. **Header scrolling/expanded avatar gate**: active profile fragment cached`.35s`; field `avatarBig` non-null → hide; первый list child adapter position>0 → hide; при pos0 relative top≤4dp и relative bottom<`max(16dp,pa_height*.45)` → hide. Base window-coordinate offset cached`.40s`. Нет active fragment/exception → этот gate false. **S:L3232–L3282**.
2. Exact fields `isVisible`/`visible`, когда присутствуют и false → hide. Exact animation/float fields `alpha`, `showAlpha`, `buttonsAlpha`, `actionsAlpha`: через `.get()` если доступно; любой присутствующий≤.05 → hide. Это **guards**, не все множители final alpha. **S:L3221–L3230; L3295–L3307**.
3. Existing canvas clip bounds: если clip пустой — hide; individual rect должен пересекать clip минимум12dp по width и14dp по height. **S:L3309–L3321; L3440–L3442**.
4. Field `glass` может быть list drawables или shared drawable. Все identities запоминаются как handled. Shared alpha≤12 → hide; иначе background alpha fraction. Если glass absent/empty, probe `paint` или `backgroundPaint`: после однажды наблюдённой alpha>12 значение≤8 suppresses stale overlay. **S:L3323–L3367**.
5. Fields/defaults `clipHeight=-1`, `ypadding=0`, `top=0`, `currentHeight=0` (fallback view height), `targetHeight=1`. ClipHeight с учётом view Y должен оставлять больше `ypadding+top+10dp`; `height=max(0,currentHeight-ypadding-top)`; height/targetHeight должны быть positive. **S:L3369–L3392**.
6. `fraction=clamp(height/targetHeight,0,1)`; `alpha_frac=clamp((fraction-.68)/.32,0,1)`; `alpha_frac<=.05` suppresses. `getRoundRadius()` fallback16dp. `actions` required, иначе no draw. Optional `canvas.clipRect(0,max(0,top+ypadding*.25),view_width,clip_bottom)`. **S:L3393–L3414**.

Каждый action из `actions.size()`/`.get(i)` (**S:L3418–L3489**):

- `isDeleted=False`; deleted skip. Field `rect` required. Width≥24dp, height≥32dp; partial clip thresholds выше. При clip_bottom≥0 visible portion должно составлять≥65% action height, и bottom>4dp.
- `getScale()` default1, ≤`.25` skip. `getAlpha()` default1, fallback animation/float field `alpha`; `textAlpha` присутствующий≤`.05` suppresses, **не** умножается автоматически. Glass-list item alpha≤12/пустые bounds/height<16dp/width<20dp suppresses этот action; иначе item alpha/255.
- Final **`btn_alpha=act_a*alpha_frac*view_alpha*gd_alpha_f`**, threshold`.04`. Это реальная вычисляемая intensity profile actions; нет отдельного persisted key.

**Reference bounds и shrink** (S:L3491–L3547): когда fraction>`.97`, сохраняются fully-expanded `(pw,ph)` per view/action index; обновляются при drift>6dp. При min(actual/reference ratios)≤`.68` action overlay не рисуется. Если есть ref и scale<`.999` или actual dimensions<`.98` ref, draw reference rect с centered transform `sx=pw/rw*action_scale`, `sy=ph/rh*action_scale`. Без ref action scale используется как visibility gate, но не эта transform branch. Это важная source особенность, не повод менять own frame.

Обе drawing branches: `draw_wash=False`, `max_ph_dp=120`, `corner_rad=actual radius`, `thin_decor=True`, `rim_width_dp=1.15`; transform branch явно передаёт clamp по original top≤1.8dp. Invalidate минимум`.095s` только при drew_any и fraction>`.95`, затем helper gate style3/glow. Не hardcode ровно три кнопки: количество/rects/alpha/scale — host inputs. **S:L3515–L3554**.

### 8.3. Active profile и backup: существенные ограничения реального code

`_get_active_profile_fragment`: direct last fragment `ProfileActivity`; иначе `getCurrentVisibleFragment()` такого simple name; иначе `fragmentsArr.valueAt(idx)`→field `fragment` с ProfileActivity и shown fragment view. Это Android navigation discovery, native mapping — explicit typed visible-profile owner. **S:L3586–L3614**.

Backup вызывается root draw до snow gate. Он немедленно возвращает, если profile disabled **или** `_pa_ava_native_ok` (оба hooks `Prf` и `Ava` успешно установлены). На деле **`need_actions=False` жёстко**, `need_avatar=(now-_last_prof_avatar_hook_t)>.65`; проверяется время последнего **hook вызова**, не последнего успешного draw. Поэтому comment «если onDraw не вызвался» не является полной реализацией fallback для обеих features. **S:L977–L979; L1163–L1168; L2986–L2989; L3700–L3712**.

Backup берёт active profile cached`.35s`, suppresses `avatarBig!=None`, target из `avatarImage`; ветка `actionsView` присутствует, но при текущем `need_actions=False` недостижима. `_scan_profile_views_in_root` (BFS max80 nodes/depth8, skipping inner RecyclerListViews, visibility/alpha/attachment checks) **определена, но нигде не вызывается**. `_pa_native_ok` выставляется/сбрасывается, но не включает action fallback. **S:L3616–L3698; L3700–L3733; L306; L345; L419; L978**.

При root-level avatar backup собираются effective alpha/scales до16 ancestors к layout; guard visible, attached/shown, alpha>.05 и scales>.15; avatar ещё requires effectiveScaleX≥`.60`. Window coordinates переводятся относительно root, применяются translate/scale, затем тот же avatar renderer. Если что-то нарисовано и snow выключен, root invalidation минимум`.055s` через helper. **S:L3735–L3793**.

**Native expectation:** зарегистрированные typed avatar/actions hosts дают надёжный lifecycle; не обещать «полный action backup» как уже существующую source feature. Missing required host adapter должен быть unsupported/error в bridge; placeholder пустой success недопустим. Исправление этих Android fallback ограничений — осознанное отличие native implementation, не byte-identical перенос.

## 9. Profile section cards: ownership, grouping, clipping

### 9.1. Какие списки вообще разрешены

`_is_profile_section_rv` требует profile flag, наличие хотя бы одного non-null `isSectionView`, `bitmapSectionsItemDecoration`, `sectionsItemDecoration`, и active profile fragment view среди максимум8 parents rv. Positive result кэшируется без TTL до очистки cache; negative повторно проверяется не ранее15s. Обычные chat/media RecyclerListViews не должны получать card decorations. **S:L3795–L3836**.

Metadata: callback `isSectionView` из rv, иначе decor и callback `isSectionView`/`isSectionItem`; `sectionRadius` default16dp, nonpositive→16dp; `emptyView`. Если callback и decor отсутствуют — no draw. Callback вызывается `.run(child)`; при отсутствии callback, но существующем decor fallback section membership=`child.getTag() is None`. **S:L3838–L3871; L3966–L3970**.

### 9.2. Как строятся группы и alpha

- Width/height rv positive, visible children required. Empty view, invisible child, alpha≤`.05`, inset слева/справа<4dp, excluded classes/substrings из §3.2, failed/false membership → **flush текущей группы**. **S:L3873–L3885; L3929–L3976**.
- Group начинается первым qualifying child; top/bottom объединяются по `getY()` и height. Group splits при alpha difference>`.10`, forward gap>10dp или обратном разрыве>10dp. Group alpha — alpha **первого** child, max1, не среднее и не minimum всех children. **S:L3978–L3991; L3924**.
- На flush: left/right берутся от первого child с translationX, оба outer insets≥4dp, group width≥120dp, group height≥28dp; иначе группа не добавляется. **S:L3910–L3927**.
- Cached fast path при прежнем child count, first/last identity, rv width и возрасте<1.5s: старые groups сдвигаются на delta first child Y. Средние children, tags/membership/alpha/section metadata при cache hit заново не проверяются. **S:L3881–L3901; L3993–L3995**.

### 9.3. Draw contract и частично скрытые edges

Для видимой группы (`bottom>0`, `top<rv_height`): shared style/palette, alpha=`group_alpha*rv_view_alpha`, no wash, **max height1800dp**, **corner radius из sectionRadius**, thin decorations, rim1.20dp. `draw_top=(top>=-36dp)` и `draw_bot=(bottom<=rv_height+24dp)`. Это групповой card perimeter, **не rim каждой строки**. **S:L3997–L4023**.

У profile cards нет отдельного periodic invalidation даже при style3: animation обновляется, только когда rv/root/другой trigger перерисует canvas. Сохранение живого alpha/geometry в native host — обязательно; слепое копирование stale Android grouping cache может дать overlays при disappearing/recycled rows. Tall card bitmap-strip особенности и top/bottom source limitations см. §10.

## 10. Runtime caching, repaint policy, refresh и диагностика

### 10.1. Geometry/baking caches

| Cache | Реальный key/лимит/условия | SOURCE |
|---|---|---|
| `_nav_geom` / `_nav_cache_key` | integer w/h + theme; full paths, builder всех styles, не sprite bake в navbar path | S:L2137–L2150 |
| `_avatar_cache` | rounded w/h/inset + theme + style + palette(styles0/2); max12 inserted variants; third hit + global bake budget; static bitmap ≤2048×2048 | S:L1852–L1928; L1929–L1932; L2019–L2038 |
| `_glass_cache`, small baked | rounded pw/ph/corner + thin/clamp/theme/style + draw_wash + rim width bucket + palette; max64; third hit; `pw<=600dp`, full bmp bounds≤2048×1024; static bitmap incl rim/cap/icicles/wire/bulbs | S:L2476–L2534; L2536–L2622 |
| `_glass_cache`, path / no bake | rounded dimensions/corner + thin/clamp/theme + sentinel-1; build-all style paths; **key не содержит draw_wash/style/rim/palette** | S:L2495–L2496; L2518–L2533; L2872–L2882 |
| `_glass_cache`, tall baked | height>120dp → cache key height-1, builder reference height`round(140dp)`, width/corner/thin/clamp/theme/style/palette; drawing uses top/bottom strips | S:L2490–L2494; L2517; L2623–L2640 |
| `_strip_cache` | rounded pw/corner + thin/clamp/style/palette; **нет height/theme**; max24; top bitmap ширина≤2048, bottom bitmap height≤256; общий strip для tall geometry | S:L2355–L2386; L2428–L2467 |
| Sized snow | source bitmap identity + 4px diameter; max96; size multiplier change clears cache | S:L1273–L1284; L1344–L1361 |

Global `_can_bake_now` разрешает очередной expensive bake не чаще `.015s`. Full/static или strips отмечаются baked после достаточного количества hits; sparks остаются dynamic. **S:L2469–L2474; L1857–L1865; L2536–L2544; L2623–L2640**.

**Особенности tall/strip path, которые нужно знать до native port**:

1. `thin_decor and is_tall` builder создаёт **без frost rim shader**. До baking unbaked tall thin card не получает rim из ordinary shader branch. Baked strip branch для styles0/1/3 рисует simplified rim alpha`95*target_alpha`, RGB`(220,242,255)`, actual rim width; тогда появляется rim. Это различие пути source, не визуально подтверждённая плавность. **S:L1695–L1707; L2528**.
2. Strip branch уважает `draw_top/draw_bot`; full static bmp и unbaked paths — нет. Native clipping contract должен явно определять visible edges во всех rendering paths. **S:L1685–L1764**.
3. Geometry tall canonical height140dp, а bottom-strip baking получает actual ph и сдвигает canvas на `-(ph-bot_off_y)`; shared strip key не включает height. Соответствие bottom icicles для всех tall heights нельзя предполагать или объявлять проверенным. **S:L2517; L2428–L2443; L2630–L2638**.
4. No-bake key omits `draw_wash`, хотя shader создаётся по `draw_wash` первого caller. Поэтому native cache key должен покрывать **все реально влияющие render configs**, а не копировать incomplete key буквально: shape, size/radius, theme/material, style, palette, wash, thin, rim width, edge visibility/bake variant. Source settings cache сам по себе недостаточен.

### 10.2. Invalidation matrix: Android intervals, не обещанный native FPS

`_throttle_view_inval` ничего не делает, если neither style3 nor glow; после time check требует visible/attached/shown, сохраняет per-view monotonic timestamp, вызывает `postInvalidateOnAnimation()`. Это immediate next-animation invalidation с throttling по реальным draw calls, **не** гарантированный таймер на каждом указанном интервале. **S:L2931–L2946**.

| Caller | Minimum interval / дополнительный gate | SOURCE |
|---|---|---|
| Eligible snow root | delayed20ms, `now>=_snow_next_inval`; не использует style/glow throttle helper | S:L1206–L1208 |
| Navbar | `.080s` + helper style3/glow | S:L2353 |
| Generic blurred drawable callback | `.095s` только style3 и drawable alpha>12 | S:L2718–L2725 |
| ActionBar / filters | `.140s` после successful draw + helper | S:L3097–L3099; L3123–L3125 |
| Search / profile TabsView | `.140s` только style3 | S:L3152–L3155; L3171–L3174 |
| Chat input | `.050s` только style3 | S:L3198–L3200 |
| Profile actions | `.095s` drew_any и fraction>.95 + helper | S:L3552–L3553 |
| Profile avatar | `.140s` только style3 | S:L3210–L3214 |
| Avatar root backup без snow | `.055s` any_drew + helper | S:L3792–L3793 |
| Section cards | собственного request нет | S:L3838–L4023 |

Из-за этого glow-only ordinary sparkles могут зависеть от redraw других элементов, а thin static actions могут запросить repaint из-за global glow даже без своих extra sparkles. Native generation-bound display clock может выровнять scheduling, но это нужно документировать как native adaptation и подтвердить recorded frames позже.

### 10.3. Refresh и ошибки

`_refresh_screen` через `run_on_ui_thread`: last navbar invalidate; last fragment ActionBar и fragment view; иной active-profile fragment view; last root, иначе parent DrawerLayoutContainer, иначе parent view/container. `_invalidate_target` принудительно `setWillNotDraw(False)` + invalidate. Source не хранит прежнее willNotDraw для восстановления. **S:L4025–L4079**.

Errors: outer root hook записывает `draw: ...` и логирует один раз `_draw_error_logged`; navbar `nav_pre/nav_post`, generic `glass`, view modes `vp_*`, graphics `gfx`, snow `snow`, backup `prof_bk` попадают в `_last_error`; часть Android lookup/cleanup exceptions swallowed. UI в конце — version Text и, если error не «нет», Text «Ошибка» с **первые120 symbols** `_last_error`. Нет UI reset и полноценной performance/visual validation страницы. **S:L131–L204; L375–L379; L790–L792; L1163–L1168; L1201–L1204; L4224–L4237**.

### 10.4. Cleanup gaps source: не переносить resource leaks в native lifecycle

`_recycle_bitmaps` явно освобождает base/rotated snow sprites, snow offscreen placeholder, bulb sprites, geometry/static/strip bitmaps и большинство collections. Однако **`_snow_sized_cache` динамически создан в render loop и не включён в on_load/on_unload recycle**; dynamic reflection/time fields вроде `_pa_ckey`, `_pa_act_ckey`, `_ava_ckey`, `_pa_frag_meta`, `_pa_scroll_win_cache`, `_gd_has_padded` не перечислены среди resets. Step0 rotated crystals alias base sprite, так что recycle list содержит повторные ссылки. Это статические риски владения, не наблюдавшийся runtime crash. **S:L330–L367; L403–L501; L709–L722; L1273–L1284; L3290–L3293; L3424–L3426; L3571–L3574**.

Нативная реализация обязана иметь single ownership textures/paths, полную cleanup subscriptions/cache/host references по generation и безопасный eviction. Нельзя оправдывать оставшиеся callbacks или native pointers тем, что Android код некоторые поля не сбрасывает. Source refresh closure не имеет generation revocation guard; требование bridge родителя для native здесь **строже** источника.

## 11. Native iOS mapping expectations и границы AyuPluginBridge

### 11.1. Минимальный strongly typed контракт будущего renderer

Ниже — **ожидания к будущему нативному модулю**, не найденные/добавленные здесь Swift symbols и не инструкция менять app integration в этой inspector задаче.

| Native responsibility | Входы / ожидаемое поведение | Android основание |
|---|---|---|
| Typed immutable configuration snapshot | Все15 keys, typed enums с exact raw index/defaults, bool; internal migration marker отдельно от renderer. Snapshot обновляется при settings change, не сериализуется в каждом draw. | S:L1053–L1082; L4081–L4223 |
| Shared native simulation clock | Monotonic elapsed, clamped dt, единый advance за display tick; density/style/count/wind logic на Swift value state. Generation-bound attach/detach scheduling. | S:L1141–L1155; L1193–L1228; L1288–L1317 |
| Snow particles / sprites | Полный state §4, 3 layers, 3 snow styles, count presets, wrapping/fades, tinted generated assets. Custom particle simulation для fidelity; простой stock emitter без LUT/layer/variant logic недостаточен. | S:L66–L128; L503–L610; L1210–L1369 |
| Reusable decoration view/layer | Рисует только в предоставленных `bounds`/host coordinate space; owner controls placement. **Никогда не меняет own `frame`**. Не добавляет hit targets и не мешает app accessibility/gestures. | Canvas contract S:L2834–L2929; parent view-style guidance |
| Navbar pre/post adapters | Actual pill geometry + выбранный target rect/translations; pre wash/fill и post style/rim/sparkles, без text/icon modification. | S:L2225–L2353 |
| Explicit glass host adapters | Background bounds, optional actual path/radius, target alpha, role, drawInputBackground/suppression flags, clip; owner exceptions из §7, не глобальный overlay на каждый rounded control. | S:L2643–L2725; L3034–L3201 |
| Explicit profile-avatar adapter | Bounds, effective visibility/alpha/scale, progressToExpand, hasStories, progressToInsets, foregroundAlpha; холодное кольцо всех styles, full fade/story-inset logic. | S:L2999–L3029; L3556–L3584 |
| Explicit profile-actions adapter | Individual typed actions с rect, deleted, alpha/scale/text visibility, backgrounds; expansion fraction/current/target height, header visibility, corner radius, clip. Не hardcoded3 и не generic whole-view pill. | S:L3232–L3554 |
| Explicit section-card adapter | Active profile ownership, visible grouped-section rects/radius/alpha, empty/header/media exclusion semantics и visible top/bottom edges; обновляется при recycling/scroll/alpha changes. | S:L3795–L4023 |
| Native caches / ownership | Cached generated textures/paths/materials, bounded resources, full cache identity из всех render inputs; no stale view refs. CoreGraphics/CALayer transforms вместо layout side effects. | S:L451–L501; L1852–L2038; L2355–L2641 |
| Diagnostics / lifecycle | Explicit unsupported/error для отсутствующего required host/API, generation revocation на unload, native resource cleanup; source UI default/reset distinctions сохранить. | S:L330–L449; L794–L1051; L4025–L4237; parent bridge guidance |

Управление UIKit target view должно быть на UI actor/thread; native animation/simulation не должна ждать Python synchronously. Конфигурация, сообщения lifecycle и typed geometry updates могут поступать отдельно от draw; **per-frame JSON или main→Python roundtrip недопустимы**. Android field names в каталоге описывают semantics, а не публичные iOS APIs, которые можно «вызвать по строке».

### 11.2. Experimental bridge: обязательные ограничения acceptance

Эти требования **переданы родителем из target-repo bridge guidance**, не выдаются за поведение Android source:

1. **Import не выполняет `.plugin`**. Этот отчёт и JSON — статический каталог; нельзя `exec`/import attachment для извлечения `create_settings`, texture generation или defaults.
2. **Нет auto Python plugin execution на app startup.** Native host registration/attachment и enable управляются явно. Migration не служит поводом запустить импортированный пользовательский code.
3. **Только explicit UIKit host adapters.** Не подменять Android private `find_class`/reflection эквивалентами arbitrary iOS class scans; отсутствующая role/API — явный unsupported/error, а не empty success.
4. **Нет synchronous main→Python waits и per-frame JSON.** Settings snapshots и геометрические structs передаются типизированно; particle state/materials/drawing остаются native.
5. **Revocation по plugin generation на unload.** Проверять generation у queued UI refresh, clock callbacks, host attachments и любых старых callbacks; после revoke не рисовать, не сохранять pointers/views и не менять preferences от старой generation.
6. **Не публиковать attachment source** и не добавлять его как build resource. Родитель публикует только разрешённые native module files/report artifacts; исходный `atmospheric_snow.plugin` остаётся пользовательским локальным файлом.
7. **BUILD + manager + typed host attachment/integration остаются вне этой inspector задачи.** На pinned branch новый snow module отсутствует. Даже если отдельная родительская задача создаст module files, это не означает, что они включены в target, скомпилированы, подключены или визуально проверены.
8. **Recorded frames обязательны для финальной animation/visual acceptance.** Здесь ни records, ни screenshots, ни native build не выполнялись; нельзя закрывать эти acceptance пункты по одному наличию renderer source.

### 11.3. Что не может быть byte-identical между Android и iOS

- `density_px` конвертирует dp в Android **pixels**; UIKit points и Retina content scale — другая система. Семантические dp размеры обычно переносить в points, raster assets — с native scale; raw-pixel guards80/4…64px/quantization отдельно документировать. Нельзя механически подставить `UIScreen.scale` вместо `_density_px` во все formulas и получить одинаковые физические размеры.
- Android Canvas/Paint/LightingColorFilter, gradient interpolation, bitmap filtering, premultiplied alpha и color-space rasterization отличаются от CoreGraphics/CALayer. Нужно сохранить RGB/alpha stops, geometry и compositing intent, **не** обещать совпадение bytes framebuffer.
- Android draw hooks/navigation fragments/blur backend классы не существуют на iOS в этой форме. Typed UIKit host roles могут покрыть функционально те же области, но exact bounds, story/expanded-avatar transitions, card grouping и layout order определяются iOS host.
- Python `random` без seed и фактические monotonic timings делают два исходных запуска разными. Native RNG/displays60/120Hz, displayLink scheduling и clipping также не дают тех же particle positions побайтно. Deterministic seed полезен для **будущих native тестов**, но не найден как настройка исходника.
- Pixel/alpha/rotation buckets, reference avatar96dp и canonical tall140dp — Android optimizations. Их сохранение или сознательная native адаптация должно быть указано; continuous rotation/exact alpha без buckets тоже уже отличие.
- Замена broken/incomplete backup, stale cache keys, unclear tall strips или nonuniform scheduling корректными explicit adapters — обоснованный native deviation; не рекламировать как byte-identical Android behavior.

**Контракт fidelity:** точно перенести keys/defaults/ranges/migration, functional scopes, source styles/palettes, particle distributions/formulas, drawing roles и visibility/fade gates; платформенные отличия назвать отдельно и проверить позднее настоящими native build/recorded frames.

## 12. Структурированный actionable feature checklist

Все `[ ]` ниже — **не выполненные этой инспекцией implementation/acceptance пункты**. Они пригодны для отдельной native задачи; SOURCE anchors дают критерий, а не свидетельство реализации. Изменения BUILD/manager/host attachment и native verification не разрешены этому inspector.

| Статус / ID | Feature и native mapping expectation | SOURCE / будущий acceptance |
|---|---|---|
| [ ] CFG-01 | Сохранить все15 keys и exact typed selector indices/defaults, плюс marker отдельно; в snapshot не забыть glass/profile flags и общий style/palette/glow. | S:L1053–L1082; L4088–L4223. Проверить каждый допустимый index и fallback отрицательного/out-of-range/malformed index. |
| [ ] CFG-02 | Migration v1: absent/invalid/<1 marker перезаписывает7 snow selectors; ≥1 сохраняет настройки; version1.0.1 не migration2. | S:L384–L401. Тест existing customized values с/без marker; marker last/partial failure semantics. |
| [ ] CFG-03 | Независимые snow/navbar/glass/profile switches; area только snow, profile tabs относятся к glass. | S:L1092–L1114; L1163–L1175; L2978–L2982. Проверить все groups отдельно и combined disabled cases. |
| [ ] CFG-04 | Reset/clear не выдавать за source UI feature; при host addition namespace-only reset точными defaults, cleanup без глобального wipe. | S:L403–L449; L4088–L4237. Проверить сохранность preferences после unload и повтор migration после clear marker. |
| [ ] SNOW-01 | Полный particle state и 48/34/18% layers с заданными ranges/variants/crystal flags, без depth sorting. | S:L66–L128. Native deterministic/statistical tests; без запуска Python attachment. |
| [ ] SNOW-02 | Fixed counts26/50/82; добавление/удаление сохраняет остальные flakes; >80px bounds reset, respawn/wrap margins. | S:L1116–L1122; L1230–L1240; L1300–L1305. Проверить bounds changes/count switching. |
| [ ] SNOW-03 | Vertical speed presets, wind gust/layer factor, двухчастный LUT sway, spin dt clamp и единые часы. | S:L31–L32; L1141–L1155; L1223–L1228; L1244–L1246; L1288–L1298. Numeric trajectory tests по заданным states. |
| [ ] SNOW-04 | `snow_style=0`: grain layer0 + bokeh layers1/2, draw radii1.25/.95. | S:L1327–L1340. Recorded frames позже; no false «все particles bokeh». |
| [ ] SNOW-05 | `snow_style=1`: crystals layers1/2 независимо от `is_crystal`, grain layer0; 3 variants и6 rotation buckets. | S:L703–L722; L1327–L1334. Tests selection/buckets, future recorded frames. |
| [ ] SNOW-06 | `snow_style=2`: crystals по `is_crystal`, остальные grain, **не bokeh**. | S:L1327–L1340. Test exact branch selection. |
| [ ] SNOW-07 | Size/opacity/color presets, fade7%/88%, layer shimmer,255 saturation и alpha buckets; size не изменяет motion. | S:L25–L42; L1258–L1260; L1307–L1369. Numeric tests границ и themes. |
| [ ] SPR-01 | Generated bokeh/grain/crystals/rotations/bulbs/sparkle assets с указанными gradients/branches; cache ownership не alias-recycle. | S:L503–L767. Native texture tests/build позднее, attachment не resource. |
| [ ] DEC-00 | Style0: snow cap/crest + rim + static garland по adaptive geometry; shared across enabled roles. | S:L1485–L1523; L1658–L1778. Future role-by-role recorded frames. |
| [ ] DEC-01 | Style1: cap/rim/icicles/highlights, нет wire/bulbs; avatar exception без icicles. | S:L1553–L1614; L1731–L1764; L2091–L2108. Test feature masks и edge clipping. |
| [ ] DEC-02 | Style2: only wire/bulbs на pills, no rim/cap/icicles; avatar retains cold ring, palette не forced gold. | S:L1766–L1778; L2078–L2124. Test all3 palettes. |
| [ ] DEC-03 | Style3: rim + pulsing sparkles, не aurora-field invention; works with glow switch false. | S:L1780–L1785; L2126–L2130. Future recorded animation, exact pulse range. |
| [ ] DEC-04 | Все3 garland palettes циклические и bulbs статичны; navbar/circle/compact/normal/thin counts, wire sag и radii. | S:L45–L52; L1409–L1483; L1525–L1551; L1787–L1850; L1969–L1992. Geometry/numeric tests. |
| [ ] NAV-01 | Explicit navbar pre wash/selected fill, post decor/selected rim/две искры; selected rect с translations. | S:L2137–L2353. Later native adapter attachment + recorded frames; здесь не интегрировано. |
| [ ] GLS-01 | Generic glass drawable bounds/path/alpha filters, wash, navbar/action exclusions и ownership dedup. | S:L2643–L2725. Test alpha≤5, min/max sizes, owner duplicates. |
| [ ] GLS-02 | ActionBar main/back/menu suppress flags и visible back target; no wash/owner alpha. | S:L3034–L3100. Typed header adapter required; missing API error, no reflection-empty success. |
| [ ] GLS-03 | Filter/folder tabs background+9dp fallback только при drawable absent. | S:L3102–L3126. Typed tabs adapter; test absent против non-null invalid background. |
| [ ] GLS-04 | Search blur→bg→padding conditional fallback; не рисовать arbitrary field при отсутствии обоих. | S:L3128–L3156. Search adapter/error semantics. |
| [ ] GLS-05 | Profile tabs glass (glass flag), single-container overlay after children, no per-child duplicate. | S:L901–L941; L2972–L2997; L3158–L3175. Native host attachment pending. |
| [ ] GLS-06 | Chat input drawInputBackground и tall520dp exception, actual path; no invented rect fallback. | S:L3177–L3201. Typed composer geometry/clipping tests. |
| [ ] PRF-01 | Avatar near-square guard, expand fade0.20…0.55, story inset/foreground state, parent alpha/scale; all4 styles. | S:L1852–L2135; L3008–L3029; L3556–L3584. Future native transition recorded frames. |
| [ ] PRF-02 | Action list любой длины, deleted/text/background/hierarchy visibility, expansion alpha threshold и canvas clip; own rect/radius. | S:L2948–L2967; L3284–L3489. Typed per-action inputs, no hardcoded3. |
| [ ] PRF-03 | Actions header-scroll suppression, reference fully-expanded bounds/shrink transforms, thin cap/bulbs/icicles/rim. | S:L3232–L3282; L3491–L3554. Native transition tests, reusable view frame immutable. |
| [ ] PRF-04 | Source backup реально только avatar, need_actions=False; native explicit adapters не обещают уже работающий action fallback. | S:L3700–L3793. Missing native adapter → explicit unsupported; если fallback расширяется, отметить deviation. |
| [ ] PRF-05 | Profile-only section grouping/ownership, exclusions и4dp margins; group perimeter не every-row border. | S:L3795–L3995. Typed card groups и recycling tests. |
| [ ] PRF-06 | Cards alpha/radius/thin,1800dp cap и clipped edges; canonical140dp/strip caveats не потерять. | S:L2355–L2641; L3997–L4023. Explicit visible-edge contract для всех paths, future frames. |
| [ ] LIFE-01 | Single native clock + visibility-based subscription, pause/detach/unload; no double time advance или unbounded invalidation. | S:L1141–L1155; L1206–L1208; L2931–L2946; §10.2. Lifecycle tests без Python draw loop. |
| [ ] LIFE-02 | Полная generation cleanup всех caches/bitmaps/callbacks/host refs; preferences сохраняются. | S:L403–L501; L1273–L1284 и parent bridge guidance. После revoke старый callback не draw/update UI. |
| [ ] LIFE-03 | Refresh/diagnostics вместо empty success на unknown bridge API; settings Text/version/error semantics по scope. | S:L375–L379; L794–L1051; L4025–L4237. Unsupported adapter явно виден в diagnostics. |

**Отдельные parent/host acceptance пункты, все pending здесь:**

- [ ] BRIDGE-A: static import no exec, explicit enable/no startup auto Python, source attachment не коммитить.
- [ ] BRIDGE-B: только typed UIKit adapters, unknown API error; no synchronous main→Python/no per-frame JSON.
- [ ] BRIDGE-C: generation revoke для queued refresh/display callbacks/targets, explicit detach/unload.
- [ ] HOST-A: BUILD registration и module dependency, manager registration, typed host attachment — работа родителя **вне allowed inspector changes**.
- [ ] VERIFY-A: реальная native compilation/type checking на корректном iOS окружении, без tool downloads этой задачей.
- [ ] VERIFY-B: recorded frames для enabled groups, all styles/palettes, selected-tab glow, avatar/actions expansion, cards scroll/clipping, themes и отключений. **Не закрыто исходником/отчётом**.

## 13. Итог inventory и передача родителю

### Что статически подтверждено

- [x] Все 4237 строк прочитаны; scoped searches подтверждают 15 user keys + 1 migration key, отсутствие отдельных intensity/glass-style/profile-style keys и reset/clear UI.
- [x] Все 14 target class names и method priorities, supporting classes, before/after order, feature gates и owner exceptions перечислены.
- [x] Все 3 snow styles, 4 decoration styles, 3 palettes, particle dynamics/sprite roles, navbar selection glow, glass exceptions, profile avatar/actions/cards и limited backup имеют SOURCE anchors.
- [x] Некэшированные dynamic renderer inputs (alpha/scale/clip/expansion/story/currentHeight/targetHeight/background flags/section grouping) описаны; они не подменены выдуманными persisted settings.
- [x] Native mapping, non-byte-identical parts, bridge safety и границы build/integration/visual acceptance отделены от поведения Android source.

### Наиболее важные gaps для native реализации

1. «Только falling snow renderer» не покрывает этот plugin: нужны glass/profile/navigation roles и все общие decoration settings.
2. Defaults — tiny45%/bright135% mixed; неверные100% defaults или интерпретация opacity как прозрачности меняют эффект.
3. Style3 продолжает sparks при glow false; style2 не force gold и не снимает avatar cold ring; mixed snow не использует bokeh.
4. Profile actions зависят от реальных animated geometry/visibility/background states, не одного boolean profile enabled; source backup actions выключен.
5. Cards только внутри active profile sections, с grouping/exclusions; tall strip/edge/bake/cached alpha paths источника имеют ограничения, требующие явной native политики.
6. Android hooks/private fields/rasters нельзя выдавать за готовые UIKit bindings. Нужны explicit typed adapters, generation revoke и позднее build/recorded-frame verification.

**Созданные inspector artifacts, и только они:**

- `/data/data/com.termux/files/usr/tmp/opencode/atmospheric-plugins-test-cc246f3/apk-analysis/atmospheric-spec.md`
- `/data/data/com.termux/files/usr/tmp/opencode/atmospheric-plugins-test-cc246f3/apk-analysis/atmospheric-settings.json`

Исходный `.plugin` не изменён/не исполнялся/не импортировался/не публиковался. В target repository ничего не менялось, network/git/shell не использовались. Никаких claims о компиляции, интеграции, кадрах, совпадении внешнего вида или завершённой анимации этот отчёт не делает.

## 14. Последующая работа родителя: не результат инспекции

Разделы 1–13 выше сохраняют исходный scope и handoff инспектора. После этой инспекции пользователь отдельно запросил действующий путь импорта/настроек/UI и публикацию в `plugins-test`, разрешив GitHub IPA CI. Это расширило scope родительской задачи на BUILD, manager и реальные UI-привязки; прежний план source-only / `[skip ci]` больше не применяется.

- `AyuAtmosphericSnow` содержит типизированные settings/migration, bounded particle simulation, native sprite/material preparation и все шесть drawing roles. Отличия UIKit points, CoreGraphics, native RNG/cache/scheduling явно описаны в module notes, а не объявлены pixel parity.
- `AyuPluginBridge/Integration/AyuAtmosphericPluginAdapter.swift` выбирается только для SHA-256 из §1, без запуска исходника. Он сохраняет 15 исходных user keys и migration marker, отклоняет устаревшие settings rows по generation, сохраняет preferences при disable и добавляет явно помеченный iOS reset.
- `AyuAtmosphericRendering.swift` переводит конфигурацию/геометрию в renderer, разделяет navbar pre/post passes, передаёт тему Telegram, агрегирует ошибки поверхности и terminally invalidates оба renderer passes при отключении.
- `AyuAtmosphericHost` владеет слабыми регистрациями, frame/geometry conversion и revoke barrier. Non-snow canvas имеет ограниченный 12-point drawing overhang для cap/halo/icicles, не изменяя исходные UI bounds или обработку касаний. `AyuAtmosphericUI` — отдельный seam явных host lifecycle events; его наличие само по себе не доказывает coverage каждого UI owner.
- Добавлены native test sources и Bazel test targets. **Эти тесты не запускались.** GitHub IPA build компилирует приложение, но сам по себе не исполняет добавленные unit-test targets.

Все implementation checklist пункты §12 остаются исходными критериями инспектора, а не отметками native acceptance. Даже опубликованные sources и успешная сборка не закрывают VERIFY-B: нужны записанные кадры реальных surfaces, transitions, scrolling/clipping, themes, touch pass-through и отключения. В Android окружении не выполнялись native build, simulator/device execution, визуальная приёмка или измерение FPS. Пользовательский attachment не является repository/build resource.
