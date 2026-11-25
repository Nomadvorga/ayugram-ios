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
| Группы и стиль | [SGSettingsController][UI] использует `appendSettingsGroup`, `expandableToggle`, `checkbox`, `visualStyle: .extera`; есть реактивные previews аватара/папок/ответов/сообщений/реакций/жестов и группы ответов, реакций, AI, переходов, автопаузы, energy и меню. | **Частично**: точный artwork/геометрия и floating-шапка не проверены; отдельный style-renderer ещё интегрируется. У меню **8** детей вместо 7; master использует `selectedCount > 0`. Нет recorded frames. |
| Двойное нажатие «Прочитать» | [Chat-модель][Chat], UI и [backup][Backup] знают `.read = 10`; [обработчик][Gestures] допускает только входящее cloud-сообщение. Incoming edit/inherit и outgoing Read исключены из picker. | **В коде** конкретного действия; новая durable очередь и её UI ещё интегрируются. Server receipt/ghost/offline и точные иконки/Cancel не проверены. |
| Нижняя кнопка «Обсудить» | [Chat-модель][Chat] хранит hidden/mute/discuss с legacy fallback; [ChatControllerNode][ChatNode] передаёт режим; [панель][Bottom] проверяет доступную связанную группу и открывает её. | **Частично**: ветвь ограничена broadcast-member и доступной discussion group; остальные действия/недоступная группа не объявлены эквивалентом Android. Нужна проверка смены режима и fallback. |
| PiP выключено | [UI][UI] при выключении пишет `.none`; [Gallery][Gallery] проверяет `.up` перед swipe-action. | **В коде** исправлена прежняя запись `.down`; все пути up/down/none, обычный dismiss и плавающий player требуют runtime. |
| Независимые AI-флаги | [AI-модель][AI] содержит независимые visibility flags; [AISettings][AISettings] описывает hero/groups, only-answer/quote/temperature, typed composer bridge и native summary routing. | **В коде** summary policy/readiness/explicit provider confirmation/cancel и draft/rights checks. **Частично** built-in roles/on-device backend, editor default и визуал Instant View; runtime/frames открыты. |
| Лента | [Контроллер][Feed] и [модель][FeedModel]: native media/albums/reactions/comments, полный локальный registry, category tabs/drag/visibility, opt-in root Feed и scoped Read All. | **Частично**: loaded-only счётчик, memory bounds 100/channel и 1000 merged, недолговечный ghost-bypass при offline; floating-шапка/обои, точные checkbox и runtime требуют проверки. |
| UI-иконки | В `f33d6382` вошли Telegram/Solar/Remix, picker с previews/авторами, provider для 37 ролей, 74 оригинальных вектора/222 PNG, consumers навигации/settings/message menu и strict backup. | **Частично**: custom import/export/editor и остальное покрытие ещё выполняются; UIKit tests/full build/кадры не подтверждены. [UIIcons] |
| Энергосбережение | В рабочем snapshot подключены threshold/Follow System, группы 2/2, 3/3, 7/7, calls/particles и реальные consumers; native autoplay/Reduce Motion сохранены. | **Частично**: iOS defaults и native ceilings документированы; подготовлены 11 model tests, сборка/исполнение/кадры не подтверждены. [Energy] |
| Pill Stack | В рабочем snapshot есть настоящий search host, editor порядка/видимости, infinite switching и шесть providers плюс HTTP. | **Частично**: Entry Time пока без доказанного provider; defaults/remote consent — iOS адаптация; full build/кадры не подтверждены. [PillStack] |

## Матрица: 87 отдельных состояний

В колонке «Код / gap» указана статическая оценка применимой части, а не процент готовности. Ссылки A/B/C/D ведут к соответствующей подробной описи; ссылки на общие места реализации раскрыты выше и ниже.

| № | Экран / функция | Код / gap | Visual/runtime |
|---|---|---|---|
| 01 | Основные: перевод, числа, секунды, вибрация, уведомления, Zalgo | **в коде** строки и хранилища; **частично** точный layout/тексты и применение; Google/Albanian — выбранные данные. [A], [UI] | НП |
| 02 | Ускорение, папка сохранения, профиль | **в коде** трёхпозиционная шкала «Откл. / Быстро / Ультра», настоящий network update и restart prompt; **частично** точная геометрия/профиль; **платформа** Android-пути → Фото/Files. [A], [UI] | НП |
| 03 | Хранилище, профиль, архив | **в коде** три настройки архива; **частично** структура профиля и условная видимость archive-on-pull; **платформа** каталоги сохранения. [A], [UI] | НП |
| 04 | Аватары, единое закругление, снег, список чатов | **частично**: slider/preview и свойства есть, нет точного бейджа/композиции, есть лишние строки и отличия subtitle. [A], [UI], [Style] | НП |
| 05 | Список чатов, папки и переходы | **в коде** title/folder flags, реактивный образец папок и отдельная страница навигации; **частично** точная композиция/notices. [A], [UI], [Navigation] | НП |
| 06 | Навигация, иконки, Pill Stack, стиль | **в коде** отдельная навигация, app/UI icon pickers и поисковый Pill Stack; **частично** custom packs/style-preview и MD3 ещё интегрируются, точная композиция не проверена. [A], [UI], [Navigation], [UIIcons], [PillStack] | НП |
| 07 | Секции 20 dp, разделители, стекло/blur | **отсутствует** пользовательская модель и UI этих опций; системный glass и общий extera-рендерер их не заменяют. [A], [Style] | НП |
| 08 | Медиалента: круглое видео, посты, реакции, комментарии | **в коде** настоящий ChatMessageItemImpl для фото/видео/кружков/альбомов, engine reactions и discussion thread; Stars открывает исходный пост; **частично** обои/floating header и полный lifecycle/runtime. [A], [FeedAudit] | НП |
| 09 | Лента: диалог «Прочитать все» | **частично**: подтверждение и scoped source-read уже в коде; ghost offline/retry ограничены, Android layout и фактический receipt не проверены. [A], [FeedAudit] | НП |
| 10 | Настройки ленты: основные, категории, каналы | **в коде** wide/counter/archive, аватары, category tabs/drag/visibility и opt-in нижняя вкладка; **частично** счётчик по загруженным постам и точная композиция. [A], [FeedAudit], [Navigation] | НП |
| 11 | Лента: «Выбрать все / Снять выделение» | **в коде** scope полного локального registry без cap40/scan2000, не более четырёх history requests одновременно; **частично** native action sheet/layout. [A], [FeedAudit] | НП |
| 12 | Длинный список выбранных каналов | **частично**: peer avatars и выбор есть; native check справа вместо круглого слева, точные карточки/разделители не сверены. [A], [Feed] | НП |
| 13 | Поиск каналов и клавиатура | **частично**: строка поиска/clear/title filter в коде; отличается переход в search-mode; **платформа** Gboard → клавиатура iOS/insets. [A], [FeedAudit] | НП |
| 14 | Общие настройки аккаунта: входы extera/Ayu | **частично**: оба контроллера существуют; хост, расположение двух входов и композиция аккаунтной страницы отдельно не подтверждены. [A], [Ayu] | НП |
| 15 | Корень AyuGram: hero, четыре категории, ссылки | **в коде** отдельный overview с bundled icon, реальной iOS version/build, четырьмя категориями и четырьмя ссылками; все прежние настройки распределены по дочерним страницам; **частично** SF Symbols вместо точных контуров и визуальная композиция. [A], [Overview], [Ayu] | НП |
| 16 | Корень exteraGram: категории и ссылки | **в коде** overview, hero, version/build, четыре применимые категории и ссылки; существующий поиск доступен отдельной кнопкой; **частично** точный artwork/layout; **исключён** пункт плагинов. [A], [Overview], [UI] | НП |
| 17 | Повтор аватаров/снега №04 | **частично** та же модель/preview; бейдж, subtitle и структура отличаются; движение снега по JPEG не установлено. [A], [UI] | НП |
| 18 | Повтор переходов/общего стиля №06 | **в коде** UI icon picker/3 base packs и Pill Stack; **частично** custom packs/style-preview/MD3 ещё интегрируются, точный layout не проверен. [A], [B], [UIIcons], [PillStack] | НП |
| 19 | Повтор списка чатов/папок №05 | **в коде** свойства, folder-preview и отдельная навигация; **частично** синхронизационный notice/точная иерархия. [A], [UI], [Navigation] | НП |
| 20 | Иконки exteraGram: низ сетки, «Аметист» | **в коде** четыре колонки, два семейства, выбор/подтверждение и реальная alternate-icon binding; 42 оригинальные иконки/628 PNG проверены по checksum; **частично** фактическая упаковка/системное переключение/геометрия. [A], [Icons] | НП |
| 21 | Повтор секций и blur №07 | **отсутствует** spacing/отделение заголовков/divider и пользовательские glass/blur-controls; совместимость не отвергнута. [A], [Style] | НП |
| 22 | Иконки exteraGram: hero, слоган, верх сетки | **в коде** оригинальный каталог/author metadata, большой hero и компактный header при scroll, draft до явного подтверждения; **частично** записанные состояния и тексты описаний (пока EN). [A], [Icons] | НП |
| 23 | Диалог нижней навигации: плавающая | **в коде** show/hide/floating и consumer реального tab host; labels/insets учитываются; **частично** точная форма native selector/баров. [B], [Navigation] | НП |
| 24 | Иконки AyuGram: 10 вариантов и выбор | **в коде** 10 оригинальных вариантов, сегменты, hero, button и штатная callback-цепочка iOS; **частично** реальное переключение/паритет. [B], [Icons] | НП |
| 25 | Навигация: tablet, bottom bar, Spring, sidebar | **в коде** отдельная страница, меню/sidebar, hide-labels и live tab-host consumers; **платформа** AOSP-animation адаптирована к drawer spring, не весь блок исключён. [B], [Navigation] | НП |
| 26 | Диалог tablet-mode: auto/on/off | **в коде** три состояния с настоящим layout consumer: on — две колонки от 700pt, off — compact, auto — window class; **частично** runtime rotation/split-window. [B], [Navigation] | НП |
| 27 | Sidebar/immersive и список пунктов меню | **в коде** реальные destinations/left-edge gesture/sidebar/spring и Reduce Motion; **частично** жест запускает анимацию без непрерывного tracking; **исключён** пункт плагинов. [B], [Navigation] | НП |
| 28 | Порядок/видимость меню и разделители | **в коде** visible/hidden editor, drag, stable dividers, cache и строгий backup; sidebar рисует разделители, top native action sheet — нет; **исключён** plugin item. [B], [Navigation] | НП |
| 29 | Скрытые элементы меню | **в коде** сохраняемый редактор с реальными Contacts/Calls/QR и account-gated wallet, Settings/Chats escape routes; **платформа** произвольное «Закрыть приложение». [B], [Navigation] | НП |
| 30 | UI icon sets: Telegram/Solar/Remix и плюс | **в коде** selector, four-icon previews, авторы и persisted base pack с реальными consumers; **частично** custom import/editor/export и оставшееся покрытие ещё в работе. [B], [UIIcons] | НП |
| 31 | Pill Stack: infinite scroll и 7 скрытых widgets | **в коде** search host, infinite/finite switching, editor порядка/видимости, weather/rates/storage/proxy/HTTP; **частично** Entry Time без доказанного provider, точное оформление не проверено. [B], [Pills], [PillStack] | НП |
| 32 | Общий стиль, шрифты/эмодзи, секции | **отсутствует** показанный набор пользовательских параметров/две миниатюры; **платформа** конкретный MD3/AOSP механизм, не весь блок. [B], [Style] | НП |
| 33 | Стикеры размер 12, ответы 3/3, rounded shape | **в коде** raw-slider 4…20, реактивная иллюстрация ответов и три shape tiles с реальными setter; **частично** точное изображение/геометрия. [B], [UI], [Sticker] | НП |
| 34 | Максимальный стикер и бейдж «БОЛЬШОЙ» | **в коде** динамический размер и бейдж при 20; **частично** визуальный паритет иллюстрации и строк. [B], [UI], [Sticker] | НП |
| 35 | Размер стикера 6, формы и ссылки | **в коде** raw-size, shape tiles и три действительных маршрута AI/calculator/chat appearance; **частично** точный artwork/layout. [B], [UI] | НП |
| 36 | Диалог времени на стикерах | **в коде** default/side/hidden; **частично** общий selector вместо доказанного визуального диалога. [B], [Sticker], [UI] | НП |
| 37 | Раскрытые ответы: цвета/эмодзи/фон | **в коде** группа/счётчик/checkbox и реактивная иллюстрация ответа; **частично** точная геометрия и mixed/master runtime. [B], [UI], [Style] | НП |
| 38 | Ссылки, recent stickers, реакции 0/3, жесты | **в коде** три маршрута/recent/group реакций, shape tiles и bubble-preview; **частично** точная композиция/оформление ссылок. [B], [UI] | НП |
| 39 | AI Chat: hero, сервисы/роли/история, editor/summary | **в коде** hero/группы, независимые visibility flags, native summary routing/readiness/confirmation/cancel и composer bridge; **частично** editor default/built-in role catalog/on-device backend отличаются. [B], [AI], [AIUI], [AISettings] | НП |
| 40 | AI: streaming, only-answer, quote, temperature | **в коде** stream, only-answer=false, quote=true, native BlockQuote/UTF-16 insertion с draft/rights check, slider 0…2 шаг0.1 и strict backup; **частично** точное оформление. [B], [AISettings] | НП |
| 41 | Вычисления: master, функции, параметры | **в коде** отдельная страница с master, функциями и auto/metric/imperial с миграцией; **частично** auto-currency из Locale вместо телефона и Space/undo. [B], [UI], [Math] | НП |
| 42 | Вычисления: 5 свёрнутых возможностей | **в коде** пять независимо раскрываемых разделов, disabled badge и копирование примеров; вычисления через общий SGMath. [B], [Math] | НП |
| 43 | Раскрытая арифметика и функции | **в коде** справка и вычисляемые/копируемые примеры; добавлены expression tests, Swift execution текущей волны ожидает Mac CI. [B], [MathAudit] | НП |
| 44 | Одновременно раскрытые арифметика и проценты | **в коде** независимые expanded states для всех пяти разделов и копируемые примеры. [B] | НП |
| 45 | Проценты и валюты: раскрытые примеры | **в коде** справочный UI и настоящие cached rates; **частично** account-specific Stars price недоступна и явно обозначена. [C], [MathAudit] | НП |
| 46 | Единицы, температура/скорость/длительность | **в коде** объяснения/примеры и выбор auto/metric/imperial; reference data checks 39 единиц/251 zone aliases/11 численных регрессий прошли, runtime Swift ожидается. [C], [Math] | НП |
| 47 | Часовые пояса раскрыты при выключенной функции | **в коде** справка при off, disabled badge и копируемые примеры. [C], [Math] | НП |
| 48 | Native chat settings: текст 16, темы, углы 17 | **частично** прямой маршрут в iOS Themes уже есть; upstream-паритет sliders/preview/name color отдельно не аудирован; avatarCorners не bubble corners. [C], [UI] | НП |
| 49 | Wallpaper picker: gallery/color/3-column grid | **частично** кандидат штатного iOS picker, полный путь/сетка отдельно не проверены; личные обои — данные, не обязательные assets. [C] | НП |
| 50 | Углы сообщений 0 и выбор 2/3 строк | **частично** theme route и chatListLines; парные previews/изменение пузыря не проверены; compact boolean не равен line count. [C], [UI] | НП |
| 51 | «Обсудить», wide 1/2, AI 3/3, переходы | **в коде** discuss, единая wide-группа с независимыми feed/channel values, AI/transitions и quick-admin 4 destinations в header; **частично** точный layout/runtime. [C], [UI], [Bottom], [Admin] | НП |
| 52 | Переходы 2/2 раскрыты, начало сообщений | **в коде** channel/topic group, tail/edited/online settings и реактивная иллюстрация; **частично** точный вид/consumer runtime. [C], [UI] | НП |
| 53 | Сообщения: хвост, edited, polls, меню 3/7 | **в коде** flags/group renderer, online toggle и preview; **частично** menu сейчас 8 детей, иной порядок/пояснения grouping. [C], [UI], [Menu] | НП |
| 54 | Preview сообщения без хвоста | **в коде** remove-tail flag и реактивное preview; **частично** точная композиция и реальный runtime renderer. [C], [UI], [Message] | НП |
| 55 | Preview с текстом «изменено» | **в коде** replace-edited flag и связанное preview; **частично** точная композиция и реальный renderer не проверены. [C], [UI] | НП |
| 56 | Online-точка у аватара сообщения | **в коде** default-false setting, backup, presence subscription только для видимого подходящего user/avatar, expiry timer и preview; скрытая presence не трактуется как online. [C], [UI], [Message] | НП |
| 57 | Forward count 67, online, edited/time | **в коде** реактивная иллюстрация forward/online/edited/tail, связанная с настройками; **частично** точное резервирование ширины и runtime renderer. [C], [UI], [Message] | НП |
| 58 | Конец сообщений, язык речи «Нет», удалить модель | **в коде** отдельное disabled «Нет», persisted настройки/backup и реальный Apple release app reservation; физическое удаление общих Apple assets определяет iOS. **Gap** Vosk применим к iOS и переносится отдельно. [C], [SpeechRuntime], [Vosk] | НП |
| 59 | Меню сообщения раскрыто: 3/7 | **частично** все 7 исходных flags + group UI в коде; лишний восьмой export, grouping перед группой, семантика действий/переноса вниз не сверена. [C], [UI], [Menu] | НП |
| 60 | Vosk и камера: Camera 1/основная/память/zoom | **в коде** zoom controls/memory и Apple speech manager с installed-only runtime; **платформа** конкретный Camera 1 backend; Vosk packaging остаётся gap. [C], [MediaRuntime], [SpeechRuntime] | НП |
| 61 | Языки речи: «Нет», верх списка | **в коде** раздельные Нет/Авто/locale/managed mode, download/use/release/cancel и checks при старте/результате; **частично** динамический Apple inventory отличается от 24 Vosk языков и порядка Android. [C], [SpeechRuntime] | НП |
| 62 | Языки речи: нижняя часть 24-языкового каталога | **в коде** настоящий каталог AssetInventory iOS26+ с lease/install/release; **частично** нет гарантии всех 24 Vosk-языков, старые iOS показывают предел management. [C], [SpeechRuntime] | НП |
| 63 | Камера, статичный zoom, HD и hide camera tile | **в коде** zoomSlider/staticZoom с реальными bounds обоих capture backends, release/flip neutral reset; **частично** HD/hide tile и floating replacement tap/hold; **платформа** Camera 1. [C], [MediaRuntime], [UI] | НП |
| 64 | Видео: seek 10, original, PiP off, автопауза | **в коде** volume-unmute setting/backup/KVO consumer с active/visible/owned/playing gates и PiP none guard; **платформа** public outputVolume не различает hardware/Control Center, endpoint key не наблюдается; runtime остаётся открыт. [C], [MediaRuntime], [Gallery] | НП |
| 65 | Автопауза раскрыта: video/voice/round 1/3 | **частично** три flags + master/count/checkbox в коде; реальное lock/background, footer и геометрия не подтверждены. [C], [UI], [Media] | НП |
| 66 | Другое: поддержки, Google telemetry, экспорт | **частично** экспорт через backup-route; **отсутствует** две support-карточки/telemetry UI/backend; обещание удаления данных не подтверждено. [C], [BackupUI] | НП |
| 67 | Другое: Ayu support, telemetry, export/reset/delete | **частично** backup export/reset отдельным экраном; нет этой композиции/support/telemetry; прямой delete-account путь по аудиту не подтверждён. [D], [BackupUI] | НП |
| 68 | Chat settings: строки списка, app icon, свайп | **в коде** отдельная страница, парные 2/3-line previews, настоящий app icon route и swipe preview/selector; **частично** точный carousel layout. [D], [ChatAppearance] | НП |
| 69 | Swipe action: архивирование/прочтение | **в коде** сохраняемый selector и native full-swipe ordering, включая inverse unarchive/unread; **частично** runtime gesture/visual. [D], [ChatAppearance] | НП |
| 70 | Swipe action: закрепление/удаление | **в коде** pin/delete через существующие callbacks, ограничения и native confirmation сохранены; **частично** carousel geometry. [D], [ChatAppearance] | НП |
| 71 | Swipe action под системной screenshot-панелью | **частично** тот же не сверенный контрол; **платформа** Android screenshot-toolbar — системное окружение, не app UI. [D] | НП |
| 72 | Swipe action: mute/change folder | **в коде** mute/unmute и выбор папки списка через switchToFilter с лимитами; membership не меняется; **частично** точный UI/жест. [D], [ChatAppearance] | НП |
| 73 | Ночная тема, browser, Animations, Stickers | **частично** native theme/settings кандидаты; точный состав/входы этой страницы отдельно не аудированы. [D], [UI] | НП |
| 74 | Светлая тема: свайп, ночь, browser, media/audio | **частично** нативные кандидаты; **отсутствует** доказанный layout/teal accent и parity всех toggles; светлая тема отдельный gate. [D], [Style] | НП |
| 75 | Энергосбережение: threshold и свёрнутые группы | **в коде** native threshold, Follow System и status, три группы, calls/video/GIF/particles; **частично** native defaults/ceilings отличаются, runtime/кадры не проверены. [D], [Energy] | НП |
| 76 | Energy: раскрыты stickers 2/2 и emoji 3/3 | **в коде** точные 2/3 children, checkbox/count/master и независимое раскрытие, настоящие animation consumers; **частично** Swift execution/runtime/кадры. [D], [Energy] | НП |
| 77 | Energy: chat animations 6/7 | **в коде** семь children, mixed 6/7 с включённым master, реальные gates blur/glass/wallpaper/sidebar/spoilers/scale/deletion; **частично** runtime/визуал и style intersection ещё проверяются. [D], [Energy] | НП |
| 78 | Управление стикерами/эмодзи и наборами аккаунта | **частично** штатный Telegram-кандидат; точный маршрут/quick reaction/suggestions/recent ordering не аудированы, size/shape не заменяют эту страницу. [D], [Sticker] | НП |
| 79 | Media/audio, microphone, Direct Share, 18+, Enter, distance | **частично** нативные кандидаты отдельно не сверены; **платформа** Direct Share → Share Extension/контактные suggestions, не Android Intent. [D] | НП |
| 80 | Distance dialog: auto/km/miles | **в коде** отдельная 3-state модель/selector/backup, оба Geo-formatters и proximity picker; engine хранит метры; **частично** Mac MapKit tests/runtime pending. [D], [ChatAppearance] | НП |
| 81 | Microphone: built-in/headset с пояснением | **в коде** auto/builtin/headset, actual input inventory и preferredInput для recording sessions, route/settings observer и disconnect fallback, CallKit/playback gates; **частично** аппаратная проверка и точное оформление. [D], [Microphone] | НП |
| 82 | Карточка AI/calculator/chat settings, реакции 0/3 | **частично** три routes, subtitle/icons и группа реакций в коде; NEW, shape-preview и полная композиция не подтверждены. [D], [UI], [Style] | НП |
| 83 | Реакции раскрыты: channel/group/private | **частично** три flags, master/count/checkbox и подключённое preview двух bubbles в коде; внешний вид и реальные реакции не проверены. [D], [UI], [Message] | НП |
| 84 | Жесты: incoming/outgoing, swipes, admin notice | **частично** selectors, preview с иконками выбранных действий, отдельная swipe-страница и notice; точный набор/иконки/admin gating не сверены. [D], [UI], [Gestures] | НП |
| 85 | Incoming double-tap: 10 действий, включая Read | **в коде** `.read` + incoming guard + backup, incoming edit/inherit и outgoing Read исключены; **частично** точные иконки/порядок/Cancel и server receipt требуют проверки. [D], [Chat], [Gestures], [Backup] | НП |
| 86 | Chats: discuss, wide 1/2, AI 3/3, переходы 2/2 | **в коде** discuss и wide/AI/transitions, default-true quick-admin switch и четыре header destinations с повторной проверкой прав; **частично** native menu вместо горизонтального ряда, точный порядок/NEW/runtime. [D], [UI], [Bottom], [AI], [Admin] | НП |
| 87 | Wide posts раскрыты: feed on / channels off | **в коде** независимые feed/channel значения, общий parent/count и настоящий ChatMessageItemImpl в ленте (media/albums/reactions/comments); **частично** media lifecycle/точная карточка. [D], [UI], [FeedModel], [FeedAudit] | НП |

## Исключения и платформенные адаптации

Плагины **исключены** во всех местах (№16, 27–29). Сохраняется требование к остальным категориям, ссылкам и редактору меню. Нельзя исключать всю строку матрицы только из-за plugin item внутри неё.

К **платформе** относятся конкретные Android Camera 1/CameraX/AOSP API, Gboard/status/gesture/screenshot chrome и общие Android-каталоги. Direct Share требует iOS-пути через системный share/contacts; tablet-mode — отдельного решения на iPad. Принудительное завершение приложения не переносится как фиктивная рабочая кнопка. Закрытый MD3 3/8 не раскрывает восемь опций: нужен разбор, а не выдуманный список.

Blur, geometry/dividers, темы, alternate app icons/UI icon sets, медиа/feed, Vosk, zoom controls, audio routes и volume-button behavior не объявлены целиком несовместимыми по факту Android-референса. Для исключения нужен конкретный API/продуктовый предел; допустимая нативная адаптация всё равно требует реализации и проверки. Отсутствующий telemetry backend нельзя заменять инертными switches или обещанием мгновенного удаления данных.

## Независимые gates приёмки

| Gate | Текущий статус | Что необходимо для закрытия |
|---|---|---|
| Исторический baseline | **Отдельный исторический результат:** `010c93d1`, build 115 — success по контексту задачи. | Этот success **не распространяется** на текущие незакоммиченные UI/AI/feed/chat/workflow изменения; не подтверждает ни одну строку матрицы. Здесь не выполнялась повторная проверка CI baseline. |
| Сборка текущего дерева | **Не подтверждена** этим документом. | Полная поддерживаемая сборка `Telegram/Telegram` через Make.py на Mac, точная ревизия + diff/хэш исходников, конфигурация, логи и хэш IPA. Правила: [CLAUDE.md](../CLAUDE.md#build). Parser/whitespace/unit-model checks не заменяют Swift typecheck/link. |
| Host-модели `96139e86` | **Success**, [run 45679479372](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45679479372), 3m23s. | Пройдены восемь групп: calculator/conversions, lyrics, serialization/validators, feed, pills, stickers, image search, takeout/ZIP. Этот результат не включает последующие изменения рабочего дерева и не закрывает UI/runtime gates. |
| Host-модели `136a2a1b` → `f33d6382` | **11/13 групп прошли**, [run 45688563370](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45688563370), 4m43s. | Две группы остановились на deprecated Locale API при warnings-as-errors. Исправления и полный UI icon checkpoint отправлены в `f33d6382`; [повтор 45689872996](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45689872996) запущен, результат ожидается. |
| Device build / запуск | **Не проверено** для текущих правок. | Собрать device-конфигурацию, установить/запустить на разрешённом устройстве; зафиксировать signing/config/OS/build/IPA hash, crashes и реально установленный бинарник. Device arm64 не равен simulator arm64. |
| Simulator build / launch smoke | **Не выполнено здесь**; инфраструктура в изменённом workflow — только код. | См. [simulator validation][Sim] и [smoke script][Smoke]: свежий IPA, IOSSIMULATOR platform, отдельный owned simulator, launch/crash evidence. Даже успешный onboarding smoke не проверяет авторизованные настройки/чаты и 87 референсов. |
| Функциональный runtime | **0/87 принятых состояний**. | На соответствующей текущей сборке пройти каждый применимый экран/действие, persistence/reopen/relaunch, Cancel/reset, mixed/master states, поиск скрытого дочернего пункта, incoming/outgoing/права, source-read/ghost/offline, PiP none/up/down, AI flags и feed scope. Ограничения [feed handoff][FeedAudit] остаются открытыми. |
| Визуал и recorded frames | **0/87 visual pass; записей текущих изменений здесь нет**. | По [AGENTS.md](../AGENTS.md#visual-features-and-animations-judge-them-from-recorded-frames) заранее описать ожидаемое движение; `simctl io recordVideo` → timestamps из ffprobe → [animation_sheet.py](../tools/animation_sheet.py). Проверить light/dark (включая №74), scroll/keyboard, expand/collapse/master/checkbox, selectors/cancel, transitions, long text/Dynamic Type/VoiceOver. Сохранять video, labelled sheets, frames.tsv и вывод с frame/time-ссылками, дефектами gaps/jumps/clipping/z-order. |
| Performance на устройстве | **Не измерено**. | Фиксировать устройство/OS/build, сценарии раскрытия/scroll/feed/media/AI, frame pacing/hitches, CPU/memory и повторяемость на реальном iPhone. Simulator timestamps подтверждают кадры/порядок, но не FPS/плавность устройства. Build/parse pass не является performance gate. |

Правила [AGENTS.md](../AGENTS.md) и [CLAUDE.md](../CLAUDE.md) действуют для выбора разрешённого simulator/device и доказательств установленного билда. Не подменять текущий IPA старым `archive-root`. Матрица обновляется по интегрируемому коду; авторизованные runtime-проверки и записи настроек/чатов пока не выполнены.

## Проверка покрытия

Проверка структуры матрицы: **87 строк, 87 уникальных номеров, полный диапазон 01…87, пропусков и дублей нет**. Все 87 имеют явный `НП` в колонке visual/runtime. Покрытие номеров не означает покрытие реализации или успешную приёмку. После последующих параллельных правок матрицу нужно сверять с новым diff; данный срез не утверждает результатов будущих сборок/записей.

[A]: extera-reference-screens-01-22.md
[B]: extera-reference-screens-23-44.md
[C]: extera-reference-screens-45-66.md
[D]: extera-reference-screens-67-87.md
[UI]: ../Swiftgram/SGSettingsUI/Sources/SGSettingsController.swift
[Overview]: extera-settings-overviews.md
[Icons]: extera-app-icon-picker.md
[Navigation]: extera-navigation.md
[UIIcons]: extera-ui-icon-packs.md
[Energy]: extera-energy-settings.md
[PillStack]: extera-pill-stack-implementation.md
[Admin]: extera-admin-shortcuts.md
[Vosk]: extera-vosk-ios-feasibility.md
[ChatAppearance]: extera-chat-appearance-settings.md
[AISettings]: extera-ai-settings.md
[MediaRuntime]: extera-media-camera-runtime.md
[SpeechRuntime]: extera-speech-runtime.md
[Microphone]: extera-recording-microphone.md
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
