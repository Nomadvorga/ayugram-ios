# exteraGram / AyuGram → iOS: единая матрица референсов 01–87

Срез: 2026-11-25, текущее **незакоммиченное рабочее дерево**. Цель — полное соответствие 1:1 всем 87 предоставленным скриншотам по применимым функциям, структуре и внешнему виду. Исключения: плагины по указанию пользователя и конкретные несовместимые с iOS механизмы. Наличие похожей функции Telegram, поля настроек или успешной старой сборки не закрывает требование.

Матрица составлена по четырём покадровым аудитам: [01–22][A], [23–44][B], [45–66][C], [67–87][D]. Они содержат прочитанные тексты, состояния, имена исходных JPEG и подробные расхождения; здесь они не дублируются. Повторные состояния имеют собственные строки. Исходные снимки: `Downloads/Telegram Desktop/photo_N_2026-11-25_21-26-04.jpg`. Значения на них — состояние референсной установки, а не доказанные defaults. Личные данные, выбранные каналы, динамические курсы и версии Android не следует зашивать в iOS.

## Статусы и границы доказательств

- **в коде** — статически найден конкретный путь/поле/обработчик; не означает успешную компиляцию, выполнение или полный перенос экрана.
- **частично** — есть часть реализации или нативный кандидат, но остаются перечисленные пробелы. Если upstream-контроллер отдельно не аудирован, это прямо указано.
- **отсутствует** — требуемый интерфейс/модель не найдены в проверенном слое; границы поиска см. исходный аудит.
- **платформа** — конкретный Android-механизм или системное окружение требует iOS-эквивалента либо исключения; это не исключает остальные функции экрана.
- **исключён** — только плагины и их пункты; пользовательская папка с именем `Plugins` не является модулем плагинов.

В последней колонке **НП = visual/runtime не проверено**. Для всех 87 строк нет принятого runtime pass, визуального pass или подтверждённого анимационного паритета. Даже там, где в коде есть вся модель отдельной функции, экран остаётся открытым до проверок ниже. Документальная сверка выполнена в Windows; приложение, simulator/device и сетевые действия здесь не запускались.

## Поправки к первоначальным аудитам по текущим изменениям

Первичные аудиты описывают более ранний срез. Следующие статические находки имеют приоритет над их фразами «нет» только в указанном объёме:

| Область | Что уже в коде | Что остаётся открытым / доказательства |
|---|---|---|
| Группы и стиль | [SGSettingsController][UI] использует `appendSettingsGroup`, `expandableToggle`, `checkbox`, `visualStyle: .extera`; есть группы ответов, реакций, AI, переходов и автопаузы, а также меню. | **Частично**: [рендерер][Rows] и [его ограничения][Style] не меняют avatar/chat-list previews и slider; phone inset минимум 16 pt вместо ориентира 13 pt, нет доказанной floating-шапки. У меню сейчас **8** детей, а не 7; master вычисляется как `selectedCount > 0`, его действие меняет детей. Сохранение прежнего смешанного набора после выключения/включения не доказано. Нет recorded frames. |
| Двойное нажатие «Прочитать» | [Chat-модель][Chat], UI и [backup][Backup] знают `.read = 10`; [обработчик][Gestures] допускает только входящее cloud-сообщение и передаёт его max ID в `ayuReadHistoryOnServer`. | **В коде** конкретного действия; подтверждение доставки receipt, ghost/offline и UX picker не проверены. В outgoing-picker `Read` пропускается; лишние edit/inherit и оформление списка требуют сверки с №85. |
| Нижняя кнопка «Обсудить» | [Chat-модель][Chat] хранит hidden/mute/discuss с legacy fallback; [ChatControllerNode][ChatNode] передаёт режим; [панель][Bottom] проверяет доступную связанную группу и открывает её. | **Частично**: ветвь ограничена broadcast-member и доступной discussion group; остальные действия/недоступная группа не объявлены эквивалентом Android. Нужна проверка смены режима и fallback. |
| PiP выключено | [UI][UI] при выключении пишет `.none`; [Gallery][Gallery] проверяет `.up` перед swipe-action. | **В коде** исправлена прежняя запись `.down`; все пути up/down/none, обычный dismiss и плавающий player требуют runtime. |
| Независимые AI-флаги | [AI-модель][AI] содержит `showEditor`, `showSummaries`, `showInstantViewSummaries`; [UI][UI] имеет группу 3/3. [AI action][AIAction] повторно проверяет флаг при Send; [context menu][Context] содержит отдельное действие для уже загруженного полного Instant View. | **Частично**: флаги доступности не равны маршрутизации на пользовательский сервис — для неё остаётся отдельный `useForTextProcessing`. Нет only-answer/quote, slider температуры и hero. Instant View action в меню сообщения не доказывает паритет интерфейса внутри статьи. |
| Лента | [Контроллер][Feed] и [модель][FeedModel]: поиск, аватары, массовый выбор, категории на основной странице, persisted wide/counter и подтверждение Read All с попыткой чтения исходных каналов. | **Частично**: [handoff ленты][FeedAudit] фиксирует loaded-only счётчик, лимит загрузчика 40 каналов, границы registry scan и недолговечный ghost-bypass при offline. Нет нижней вкладки, медиарендера, floating-шапки, category tabs/drag/eye; checkbox справа. |

## Матрица: 87 отдельных состояний

В колонке «Код / gap» указана статическая оценка применимой части, а не процент готовности. Ссылки A/B/C/D ведут к соответствующей подробной описи; ссылки на общие места реализации раскрыты выше и ниже.

| № | Экран / функция | Код / gap | Visual/runtime |
|---|---|---|---|
| 01 | Основные: перевод, числа, секунды, вибрация, уведомления, Zalgo | **в коде** строки и хранилища; **частично** точный layout/тексты и применение; Google/Albanian — выбранные данные. [A], [UI] | НП |
| 02 | Ускорение, папка сохранения, профиль | **частично**: selector вместо 3-позиционной шкалы, иные подписи/лишняя строка профиля; **платформа** Android-пути → Фото/Files. [A], [UI] | НП |
| 03 | Хранилище, профиль, архив | **в коде** три настройки архива; **частично** структура профиля и условная видимость archive-on-pull; **платформа** каталоги сохранения. [A], [UI] | НП |
| 04 | Аватары, единое закругление, снег, список чатов | **частично**: slider/preview и свойства есть, нет точного бейджа/композиции, есть лишние строки и отличия subtitle. [A], [UI], [Style] | НП |
| 05 | Список чатов, папки и переходы | **частично**: title/folder flags есть; нет образца вкладок, части notices и отдельной навигационной страницы. [A], [UI] | НП |
| 06 | Навигация, иконки, Pill Stack, стиль | **частично** нативная иконка/HTTP-плашки; **отсутствует** парное style-preview и большая часть настроек; **платформа** MD3 требует разбора. [A], [UI] | НП |
| 07 | Секции 20 dp, разделители, стекло/blur | **отсутствует** пользовательская модель и UI этих опций; системный glass и общий extera-рендерер их не заменяют. [A], [Style] | НП |
| 08 | Медиалента: круглое видео, посты, реакции, комментарии | **частично** текстовая лента и открытие канала; **отсутствует** встроенный медиарендерер/загрузка/реакции/комментарии/обои/floating header. [A], [FeedAudit] | НП |
| 09 | Лента: диалог «Прочитать все» | **частично**: подтверждение и scoped source-read уже в коде; ghost offline/retry ограничены, Android layout и фактический receipt не проверены. [A], [FeedAudit] | НП |
| 10 | Настройки ленты: основные, категории, каналы | **частично**: wide/counter/archive, категории и аватары есть; нет нижней вкладки, category tabs/drag/eye, счётчик только загруженных постов. [A], [FeedAudit] | НП |
| 11 | Лента: «Выбрать все / Снять выделение» | **частично**: action sheet и bulk membership в коде; scope — загруженный registry, layout иной, загрузчик остаётся на 40. [A], [FeedAudit] | НП |
| 12 | Длинный список выбранных каналов | **частично**: peer avatars и выбор есть; native check справа вместо круглого слева, точные карточки/разделители не сверены. [A], [Feed] | НП |
| 13 | Поиск каналов и клавиатура | **частично**: строка поиска/clear/title filter в коде; отличается переход в search-mode; **платформа** Gboard → клавиатура iOS/insets. [A], [FeedAudit] | НП |
| 14 | Общие настройки аккаунта: входы extera/Ayu | **частично**: оба контроллера существуют; хост, расположение двух входов и композиция аккаунтной страницы отдельно не подтверждены. [A], [Ayu] | НП |
| 15 | Корень AyuGram: hero, четыре категории, ссылки | **частично** базовые ghost/spy/customization flags; **отсутствует** корневая структура, hero/version и блок ссылок референса. [A], [Ayu] | НП |
| 16 | Корень exteraGram: категории и ссылки | **частично** маршруты категорий, другой состав/поиск; нет hero/версии/четырёх ссылок; **исключён** пункт плагинов. [A], [UI] | НП |
| 17 | Повтор аватаров/снега №04 | **частично** та же модель/preview; бейдж, subtitle и структура отличаются; движение снега по JPEG не установлено. [A], [UI] | НП |
| 18 | Повтор переходов/общего стиля №06 | **частично** icon/HTTP-panel; **отсутствует** каталог UI-иконок, style-preview и большинство строк; MD3 отдельно. [A], [B] | НП |
| 19 | Повтор списка чатов/папок №05 | **частично** свойства есть; нет folder-preview/синхронизационного notice и точной иерархии переходов. [A], [UI] | НП |
| 20 | Иконки exteraGram: низ сетки, «Аметист» | **частично** нативный icon route; **отсутствует** показанная сетка/два каталога/подтверждение; assets и alternate-icon bundle отдельно не сверены. [A], [UI] | НП |
| 21 | Повтор секций и blur №07 | **отсутствует** spacing/отделение заголовков/divider и пользовательские glass/blur-controls; совместимость не отвергнута. [A], [Style] | НП |
| 22 | Иконки exteraGram: hero, слоган, верх сетки | **частично** переход в Themes; **отсутствует** этот picker/hero/каталоги; полный Android-каталог по двум JPEG неизвестен. [A], [UI] | НП |
| 23 | Диалог нижней навигации: плавающая | **частично** boolean show/hide; **отсутствует** 3-state show/hide/floating и отдельный диалог. [B], [UI] | НП |
| 24 | Иконки AyuGram: 10 вариантов и выбор | **частично** нативный icon picker; **отсутствует** показанная сетка, segments, hero и кнопка выбора; assets не сверены. [B], [UI] | НП |
| 25 | Навигация: tablet, bottom bar, Spring, sidebar | **частично** hide-labels; **отсутствует** отдельная страница/редактор/sidebar; **платформа** AOSP-animation. [B], [UI] | НП |
| 26 | Диалог tablet-mode: auto/on/off | **отсутствует** Extera selector/model; существующий iPad-layout не доказывает эту настройку. [B] | НП |
| 27 | Sidebar/immersive и список пунктов меню | **отсутствует** этот редактор/модель; отдельные функции в других местах не закрывают его; **исключён** пункт плагинов. [B] | НП |
| 28 | Порядок/видимость меню и разделители | **отсутствует** ordered visible/hidden editor и добавление separator; **исключён** plugin item. [B] | НП |
| 29 | Скрытые элементы меню | **отсутствует** редактор; **платформа** произвольное «Закрыть приложение»; контакты/звонки/QR не исключаются. [B] | НП |
| 30 | UI icon sets: Telegram/Solar/Remix и плюс | **отсутствует** selector/preview/import модели наборов; это отдельная функция от app icon. [B] | НП |
| 31 | Pill Stack: infinite scroll и 7 скрытых widgets | **частично** только HTTP-плашки другой модели; **отсутствует** поисковый stack/built-ins/visible-hidden editor. [B], [Pills] | НП |
| 32 | Общий стиль, шрифты/эмодзи, секции | **отсутствует** показанный набор пользовательских параметров/две миниатюры; **платформа** конкретный MD3/AOSP механизм, не весь блок. [B], [Style] | НП |
| 33 | Стикеры размер 12, ответы 3/3, rounded shape | **частично** size/time/shape модель и группа ответов; нет raw-slider/badge/реактивного chat-preview/трёх shape tiles. [B], [UI], [Sticker] | НП |
| 34 | Максимальный стикер и бейдж «БОЛЬШОЙ» | **частично** модель 4…20; **отсутствует** динамическое preview и badge/layout этого состояния. [B], [Sticker] | НП |
| 35 | Размер стикера 6, формы и ссылки | **частично** size 6 допустим, но UI в процентах; три маршрута уже есть, нет точного preview и оформления ссылок. [B], [UI] | НП |
| 36 | Диалог времени на стикерах | **в коде** default/side/hidden; **частично** общий selector вместо доказанного визуального диалога. [B], [Sticker], [UI] | НП |
| 37 | Раскрытые ответы: цвета/эмодзи/фон | **частично** группа/счётчик/checkbox уже в коде; sticker-preview и точная геометрия отсутствуют, mixed/master семантика не сверена. [B], [UI], [Style] | НП |
| 38 | Ссылки, recent stickers, реакции 0/3, жесты | **частично** три маршрута/recent/group реакций; нет shape tiles и bubble-preview, полное оформление ссылок не подтверждено. [B], [UI] | НП |
| 39 | AI Chat: hero, сервисы/роли/история, editor/summary | **частично** сервисы/роли/история и независимые flags в коде; hero/группировка страницы и точная замена Telegram AI отсутствуют. [B], [AI], [AIUI] | НП |
| 40 | AI: streaming, only-answer, quote, temperature | **частично** stream и числовая температура; **отсутствует** only-answer/quote и slider 0…2/NEW. [B], [AIUI] | НП |
| 41 | Вычисления: master, функции, параметры | **частично** отдельный маршрут уже есть, основные flags; нет выделенного master/справки, auto-measures; auto-currency из Locale вместо телефона. [B], [UI], [Math] | НП |
| 42 | Вычисления: 5 свёрнутых возможностей | **отсутствует** раскрываемая справка/disabled badge/копирование; наличие math flags не закрывает UI. [B], [Math] | НП |
| 43 | Раскрытая арифметика и функции | **отсутствует** справочное тело/чипы; поддержку каждого выражения нужно проверять отдельно. [B], [MathAudit] | НП |
| 44 | Одновременно раскрытые арифметика и проценты | **отсутствует** многосекционная справка/копируемые примеры; нельзя подменять single-open accordion. [B] | НП |
| 45 | Проценты и валюты: раскрытые примеры | **отсутствует** справочный UI; **частично** вычислительные настройки; динамические курсы и число звёзд не фиксировать как constants. [C], [MathAudit] | НП |
| 46 | Единицы, температура/скорость/длительность | **частично** inlineUnits/imperial; **отсутствует** объяснения и chips; результаты конверсий не подтверждены. [C], [Math] | НП |
| 47 | Часовые пояса раскрыты при выключенной функции | **частично** time-zone flag; **отсутствует** справка/disabled badge, просмотр примеров при off и copy. [C], [Math] | НП |
| 48 | Native chat settings: текст 16, темы, углы 17 | **частично** прямой маршрут в iOS Themes уже есть; upstream-паритет sliders/preview/name color отдельно не аудирован; avatarCorners не bubble corners. [C], [UI] | НП |
| 49 | Wallpaper picker: gallery/color/3-column grid | **частично** кандидат штатного iOS picker, полный путь/сетка отдельно не проверены; личные обои — данные, не обязательные assets. [C] | НП |
| 50 | Углы сообщений 0 и выбор 2/3 строк | **частично** theme route и chatListLines; парные previews/изменение пузыря не проверены; compact boolean не равен line count. [C], [UI] | НП |
| 51 | «Обсудить», wide 1/2, AI 3/3, переходы | **частично** discuss, AI/transition groups и отдельный feed-wide в коде; wide ещё не единая группа 1/2; **отсутствует** quick-admin action. [C], [UI], [Bottom], [FeedAudit] | НП |
| 52 | Переходы 2/2 раскрыты, начало сообщений | **частично** channel/topic group уже есть; tail/edited flags; **отсутствует** message-preview и online-indicator setting. [C], [UI] | НП |
| 53 | Сообщения: хвост, edited, polls, меню 3/7 | **частично** flags/group renderer; **отсутствует** online toggle/preview; menu сейчас 8 детей, иной порядок/пояснения grouping. [C], [UI], [Menu] | НП |
| 54 | Preview сообщения без хвоста | **в коде** remove-tail flag; **частично** перенос состояния: нет реактивного preview, runtime-render не доказан. [C], [UI], [Message] | НП |
| 55 | Preview с текстом «изменено» | **в коде** replace-edited flag; **частично** состояние/композиция: нет показанного preview, реальный renderer не проверен. [C], [UI] | НП |
| 56 | Online-точка у аватара сообщения | **отсутствует** этот toggle/model и preview в проверенном слое; ghost online suppression имеет другое назначение. [C] | НП |
| 57 | Forward count 67, online, edited/time | **частично** showForwardsCount есть; нет online toggle и preview с точным порядком/резервированием ширины. [C], [Message] | НП |
| 58 | Конец сообщений, язык речи «Нет», удалить модель | **частично** message flags и Apple/Telegram speech path; **отсутствует** Vosk/«Нет»/model removal; locale auto не означает disabled. [C], [SpeechAudit] | НП |
| 59 | Меню сообщения раскрыто: 3/7 | **частично** все 7 исходных flags + group UI в коде; лишний восьмой export, grouping перед группой, семантика действий/переноса вниз не сверена. [C], [UI], [Menu] | НП |
| 60 | Vosk и камера: Camera 1/основная/память/zoom | **частично** выбор камеры/память и speech-adaptation; **отсутствует** zoom regulator; **платформа** Camera 1 backend. [C], [Media], [SpeechAudit] | НП |
| 61 | Языки речи: «Нет», верх списка | **частично** динамический Apple locale picker; **отсутствует** Vosk-каталог/disabled «Нет» и показанный порядок. Vosk не признан iOS-incompatible. [C], [SpeechAudit] | НП |
| 62 | Языки речи: нижняя часть 24-языкового каталога | **частично** Apple locale path; наличие всех языков/офлайн-моделей не доказано, нет Vosk model management. [C], [SpeechAudit] | НП |
| 63 | Камера, статичный zoom, HD и hide camera tile | **частично** память/камера/HD-кандидат/hide tile; **отсутствует** zoom controls и доказанный floating replacement tap/hold; **платформа** Camera 1. [C], [Media], [UI] | НП |
| 64 | Видео: seek 10, original, PiP off, автопауза | **частично** flags и pause group; PiP off → none уже в коде; **отсутствует** volume-unmute setting; lock/pause и видео-поведение не проверены. [C], [UI], [Gallery] | НП |
| 65 | Автопауза раскрыта: video/voice/round 1/3 | **частично** три flags + master/count/checkbox в коде; реальное lock/background, footer и геометрия не подтверждены. [C], [UI], [Media] | НП |
| 66 | Другое: поддержки, Google telemetry, экспорт | **частично** экспорт через backup-route; **отсутствует** две support-карточки/telemetry UI/backend; обещание удаления данных не подтверждено. [C], [BackupUI] | НП |
| 67 | Другое: Ayu support, telemetry, export/reset/delete | **частично** backup export/reset отдельным экраном; нет этой композиции/support/telemetry; прямой delete-account путь по аудиту не подтверждён. [D], [BackupUI] | НП |
| 68 | Chat settings: строки списка, app icon, свайп | **частично** Themes route/chatListLines; **отсутствует** показанная swipe-карусель/preview, upstream поведение отдельно не сверено. [D], [UI] | НП |
| 69 | Swipe action: архивирование/прочтение | **частично** нативный кандидат; **отсутствует** воспроизведение данного единого контрола, его состояние/preview. Это не double-tap Read. [D] | НП |
| 70 | Swipe action: закрепление/удаление | **частично** upstream-кандидат не аудирован; **отсутствует** показанная карусель, сохранение выбора и визуальная обратная связь. [D] | НП |
| 71 | Swipe action под системной screenshot-панелью | **частично** тот же не сверенный контрол; **платформа** Android screenshot-toolbar — системное окружение, не app UI. [D] | НП |
| 72 | Swipe action: mute/change folder | **частично** upstream-кандидат; **отсутствует** соответствие единого selector/preview и всех вариантов референса. [D] | НП |
| 73 | Ночная тема, browser, Animations, Stickers | **частично** native theme/settings кандидаты; точный состав/входы этой страницы отдельно не аудированы. [D], [UI] | НП |
| 74 | Светлая тема: свайп, ночь, browser, media/audio | **частично** нативные кандидаты; **отсутствует** доказанный layout/teal accent и parity всех toggles; светлая тема отдельный gate. [D], [Style] | НП |
| 75 | Энергосбережение: threshold и свёрнутые группы | **частично** собственные energy settings iOS; список эффектов, threshold/system-mode и counters отдельно не сверены. [D] | НП |
| 76 | Energy: раскрыты stickers 2/2 и emoji 3/3 | **частично** upstream-кандидат; точные группы/checkbox/master/счётчики и потребители не аудированы. Extera renderer сам их не добавляет. [D], [Style] | НП |
| 77 | Energy: chat animations 6/7 | **частично** iOS effects-кандидаты; все 7 опций, mixed state и управление эффектами не сверены; Android toolkit не исключает блок. [D] | НП |
| 78 | Управление стикерами/эмодзи и наборами аккаунта | **частично** штатный Telegram-кандидат; точный маршрут/quick reaction/suggestions/recent ordering не аудированы, size/shape не заменяют эту страницу. [D], [Sticker] | НП |
| 79 | Media/audio, microphone, Direct Share, 18+, Enter, distance | **частично** нативные кандидаты отдельно не сверены; **платформа** Direct Share → Share Extension/контактные suggestions, не Android Intent. [D] | НП |
| 80 | Distance dialog: auto/km/miles | **частично** upstream-кандидат без отдельной проверки UI/хранилища; math imperial boolean не закрывает 3-state distance. [D], [Math] | НП |
| 81 | Microphone: built-in/headset с пояснением | **частично** требуется аудит AVAudioSession/input routes и selector; нельзя обещать headset без доступного route. [D] | НП |
| 82 | Карточка AI/calculator/chat settings, реакции 0/3 | **частично** все три routes и группа реакций в коде; subtitle/icons/NEW, shape-preview и полная композиция не подтверждены. [D], [UI], [Style] | НП |
| 83 | Реакции раскрыты: channel/group/private | **частично** три flags, master/count/checkbox в коде; **отсутствует** preview двух bubbles, внешний вид и реальные реакции не проверены. [D], [UI], [Message] | НП |
| 84 | Жесты: incoming/outgoing, swipes, admin notice | **частично** selectors, отдельная swipe-страница и notice; нет preview, точный набор/иконки/admin gating не сверены. [D], [UI], [Gestures] | НП |
| 85 | Incoming double-tap: 10 действий, включая Read | **в коде** `.read` + incoming guard + backup; **частично** весь picker: edit/inherit/иконки/порядок/Cancel и фактическое чтение требуют проверки. [D], [Chat], [Gestures], [Backup] | НП |
| 86 | Chats: discuss, wide 1/2, AI 3/3, переходы 2/2 | **частично** discuss и AI/transition groups уже есть; feed-wide отдельно, нет общей wide-группы и quick-admin; точный порядок/NEW не завершены. [D], [UI], [Bottom], [AI] | НП |
| 87 | Wide posts раскрыты: feed on / channels off | **частично** оба независимых значения существуют в feed/settings; **отсутствует** единый раскрытый parent 1/2 и точная карточка; media feed renderer не реализован. [D], [UI], [FeedModel] | НП |

## Исключения и платформенные адаптации

Плагины **исключены** во всех местах (№16, 27–29). Сохраняется требование к остальным категориям, ссылкам и редактору меню. Нельзя исключать всю строку матрицы только из-за plugin item внутри неё.

К **платформе** относятся конкретные Android Camera 1/CameraX/AOSP API, Gboard/status/gesture/screenshot chrome и общие Android-каталоги. Direct Share требует iOS-пути через системный share/contacts; tablet-mode — отдельного решения на iPad. Принудительное завершение приложения не переносится как фиктивная рабочая кнопка. Закрытый MD3 3/8 не раскрывает восемь опций: нужен разбор, а не выдуманный список.

Blur, geometry/dividers, темы, alternate app icons/UI icon sets, медиа/feed, Vosk, zoom controls, audio routes и volume-button behavior не объявлены целиком несовместимыми по факту Android-референса. Для исключения нужен конкретный API/продуктовый предел; допустимая нативная адаптация всё равно требует реализации и проверки. Отсутствующий telemetry backend нельзя заменять инертными switches или обещанием мгновенного удаления данных.

## Независимые gates приёмки

| Gate | Текущий статус | Что необходимо для закрытия |
|---|---|---|
| Исторический baseline | **Отдельный исторический результат:** `010c93d1`, build 115 — success по контексту задачи. | Этот success **не распространяется** на текущие незакоммиченные UI/AI/feed/chat/workflow изменения; не подтверждает ни одну строку матрицы. Здесь не выполнялась повторная проверка CI baseline. |
| Сборка текущего дерева | **Не подтверждена** этим документом. | Полная поддерживаемая сборка `Telegram/Telegram` через Make.py на Mac, точная ревизия + diff/хэш исходников, конфигурация, логи и хэш IPA. Правила: [CLAUDE.md](../CLAUDE.md#build). Parser/whitespace/unit-model checks не заменяют Swift typecheck/link. |
| Device build / запуск | **Не проверено** для текущих правок. | Собрать device-конфигурацию, установить/запустить на разрешённом устройстве; зафиксировать signing/config/OS/build/IPA hash, crashes и реально установленный бинарник. Device arm64 не равен simulator arm64. |
| Simulator build / launch smoke | **Не выполнено здесь**; инфраструктура в изменённом workflow — только код. | См. [simulator validation][Sim] и [smoke script][Smoke]: свежий IPA, IOSSIMULATOR platform, отдельный owned simulator, launch/crash evidence. Даже успешный onboarding smoke не проверяет авторизованные настройки/чаты и 87 референсов. |
| Функциональный runtime | **0/87 принятых состояний**. | На соответствующей текущей сборке пройти каждый применимый экран/действие, persistence/reopen/relaunch, Cancel/reset, mixed/master states, поиск скрытого дочернего пункта, incoming/outgoing/права, source-read/ghost/offline, PiP none/up/down, AI flags и feed scope. Ограничения [feed handoff][FeedAudit] остаются открытыми. |
| Визуал и recorded frames | **0/87 visual pass; записей текущих изменений здесь нет**. | По [AGENTS.md](../AGENTS.md#visual-features-and-animations-judge-them-from-recorded-frames) заранее описать ожидаемое движение; `simctl io recordVideo` → timestamps из ffprobe → [animation_sheet.py](../tools/animation_sheet.py). Проверить light/dark (включая №74), scroll/keyboard, expand/collapse/master/checkbox, selectors/cancel, transitions, long text/Dynamic Type/VoiceOver. Сохранять video, labelled sheets, frames.tsv и вывод с frame/time-ссылками, дефектами gaps/jumps/clipping/z-order. |
| Performance на устройстве | **Не измерено**. | Фиксировать устройство/OS/build, сценарии раскрытия/scroll/feed/media/AI, frame pacing/hitches, CPU/memory и повторяемость на реальном iPhone. Simulator timestamps подтверждают кадры/порядок, но не FPS/плавность устройства. Build/parse pass не является performance gate. |

Правила [AGENTS.md](../AGENTS.md) и [CLAUDE.md](../CLAUDE.md) действуют для выбора разрешённого simulator/device и доказательств установленного билда. Не подменять текущий IPA старым `archive-root`. В этом docs-only задании не выполняются установка, авторизация, действия аккаунта или коммит.

## Проверка покрытия

Проверка структуры матрицы: **87 строк, 87 уникальных номеров, полный диапазон 01…87, пропусков и дублей нет**. Все 87 имеют явный `НП` в колонке visual/runtime. Покрытие номеров не означает покрытие реализации или успешную приёмку. После последующих параллельных правок матрицу нужно сверять с новым diff; данный срез не утверждает результатов будущих сборок/записей.

[A]: extera-reference-screens-01-22.md
[B]: extera-reference-screens-23-44.md
[C]: extera-reference-screens-45-66.md
[D]: extera-reference-screens-67-87.md
[UI]: ../Swiftgram/SGSettingsUI/Sources/SGSettingsController.swift
[Rows]: ../Swiftgram/SGItemListUI/Sources/SGExteraItem.swift
[Style]: ../Swiftgram/SGItemListUI/VISUAL_STYLE.md
[Ayu]: ../Swiftgram/SGSettingsUI/Sources/AyuSettingsController.swift
[Chat]: ../Swiftgram/SGSimpleSettings/Sources/ExteraChatSettings.swift
[Gestures]: ../submodules/TelegramUI/Sources/Chat/ChatControllerExteraGestures.swift
[ChatNode]: ../submodules/TelegramUI/Sources/ChatControllerNode.swift
[Bottom]: ../submodules/TelegramUI/Components/Chat/ChatChannelSubscriberInputPanelNode/Sources/ChatChannelSubscriberInputPanelNode.swift
[Gallery]: ../submodules/GalleryUI/Sources/Items/UniversalVideoGalleryItem.swift
[AI]: ../Swiftgram/SGSimpleSettings/Sources/ExteraAISettings.swift
[AIUI]: ../Swiftgram/SGSettingsUI/Sources/ExteraAISettingsController.swift
[AIAction]: ../Swiftgram/SGSettingsUI/Sources/ExteraAIChatController.swift
[Context]: ../submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift
[Feed]: ../Swiftgram/SGSettingsUI/Sources/ExteraFeedController.swift
[FeedModel]: ../Swiftgram/SGSimpleSettings/Sources/ExteraFeedSettings.swift
[FeedAudit]: extera-feed-settings-implementation.md
[Pills]: ../Swiftgram/SGSimpleSettings/Sources/ExteraPillSettings.swift
[Sticker]: ../Swiftgram/SGSimpleSettings/Sources/ExteraStickerSettings.swift
[Message]: ../Swiftgram/SGSimpleSettings/Sources/ExteraMessageSettings.swift
[Menu]: ../Swiftgram/SGSimpleSettings/Sources/ExteraMenuSettings.swift
[Media]: ../Swiftgram/SGSimpleSettings/Sources/ExteraMediaSettings.swift
[Math]: ../Swiftgram/SGSimpleSettings/Sources/ExteraMathSettings.swift
[MathAudit]: extera-inline-conversions.md
[SpeechAudit]: extera-translation-speech-audit.md
[Backup]: ../Swiftgram/SGSimpleSettings/Sources/ExteraSettingsBackup.swift
[BackupUI]: ../Swiftgram/SGSettingsUI/Sources/ExteraBackupController.swift
[Sim]: extera-simulator-validation.md
[Smoke]: ../tools/extera_simulator_smoke.py
