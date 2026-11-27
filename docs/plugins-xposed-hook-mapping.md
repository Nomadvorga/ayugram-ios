# Xposed method hooks: mapping Android hook targets to iOS host hook points

Research and design for the reserved operation `hooks.java_method` (round 4, 2026-11-26). Nothing here is implemented. All numbers come from static analysis of the 485 `.plugin` files in `plugins/` (parsed with `ast`, never executed) and from the bridge's own preflight under a what-if host that declares all 19 operations of `submodules/AyuPluginBridge/Python/protocol-telegram.md`. The scripts are in `/Users/toby/work/_refs/plugin-bridge-scratch/xposed/` (see [Reproducing](#reproducing)); `targets.json` there lists every target with its plugins, category and proposed host hook point.

A preflight pass is the absence of static blockers, never evidence that a plugin works. "Hook-complete" below means only that every hook call of a plugin has a host hook point able to serve what its callback does.

## Summary

| Fact | Number |
|---|---|
| Plugins that call `hook_method`, `hook_all_methods`, `hook_all_constructors` or ZwyLib `HookUtils.hook_*` | 282 of 485 (preflight reports `hooks.java_method` for 281) |
| Hook call sites / resolved (site, target, callback) uses | 1,041 / 2,051 |
| Distinct resolved targets (class + method) / classes | 1,162 / 352 |
| Targets hooked by exactly one plugin / by 3 or more / by 5 or more | 948 / 80 / 31 |
| Most shared target | `LaunchActivity.onActivityResult`, 25 plugins |
| Plugins with at least one hook that mutates views, draws, or hooks draw/layout/touch | 191 (87 of them have nothing else) |
| Plugins with at least one view, Android-OS or unresolvable hook (cannot become hook-complete by any mapping) | 204 |
| Plugins whose every hook has a contract iOS can serve (static override, asynchronous flow, event, deferrable action) | 44, needing 75 distinct targets |
| ... of those, with no other preflight blocker | 8 |
| Hook-complete with the 17 host hook points proposed for stages 1 and 2 | 26 (12 after stage 1) |
| ... of those, passing preflight | 4 (0 after stage 1) |
| Hook-using plugins with no blocker other than the hooks themselves | 24 (48 if `MEMBER` and `sdk.unprovided_member` blockers are also ignored) |
| Upper bound if every one of the 1,162 targets were served, view hooks included | 259 hook-complete, 24 passing |

The mapping cannot make most hook-using plugins work. Two independent limits apply. First, 68% of hook-using plugins (191 of 282) use at least one hook whose callback manipulates Android views or a canvas. Second, hooks are rarely a plugin's only obstacle: 233 of the 282 also have `CLASS` blockers, 151 other `OPERATION` blockers and 86 `MEMBER` blockers, so even a complete mapping would add 24 passing plugins at most.

## Method and limits

`inventory.py` is a small abstract interpreter over each plugin's AST. It resolves string constants, imported Java classes, `find_class`/`jclass`/`Class.forName`, `getDeclaredMethod(s)`/`getDeclaredConstructor(s)`, `hook_utils.get_method`, ZwyLib method finders, loops over literal sequences (kept correlated), loops over `getDeclaredMethods()` filtered by `getName()`, `self.attr` assignments, list mutation, and calls of the plugin's own helpers (parameters bound per call site, three levels deep, flow-sensitive inside one function). For every hook it finds the callback (`MethodHook`/`MethodReplacement` subclass, duck-typed object, `before=`/`after=` callable, lambda) and counts what it does with `param`, following the plugin's own functions and nested lambdas that receive `param` or objects taken from it.

Limits that bound every number in this document:

- 40 of 1,041 call sites (3.8%, in 22 plugins) stay unresolved. Most name the class of a live object (`view.getClass()`, an anonymous listener), a few are invalid on Android too (a string passed as the member, a `None` method name). A further 13 sites are resolved in some calling contexts only.
- The count of 1,162 targets is higher than the earlier estimate of 369, which counted only directly written `getDeclaredMethod` calls. Loops over tables of (class, method) pairs account for the difference. A few targets may be cross products of uncorrelated loops; they inflate the tail of single-plugin targets, not the head.
- Classification is heuristic. Callback behaviour is read from names: a fixed vocabulary of view/canvas members, the member names the Python-local TL model and messenger facades provide, and reflection calls. Types of `thisObject` and arguments are not inferred. Where the analysis cannot follow an object, UI surfaces are counted as view use and non-UI receivers as internals, so the feasible categories are not inflated by unknowns.
- Validation was by reading about 45 sampled callbacks during development. That found and fixed three analyser defects (nested lambdas, higher-order delegation, aliased argument writes). In the final sample of 12 uses counted as served, the assigned contract matched the code in all 12; in 3 of them the plugin then does view work through other routes. No error rate was measured.
- The meter was run while other agents were editing the checkout (a `MEMBER` blocker kind appeared during this work and the what-if pass count moved from 47 to 43). Preflight-derived numbers are a snapshot.

## Inventory

| Hook API | call shape | plugins | uses |
|---|---|---|---|
| `hook_method(member, ...)` | one method or constructor object | 177 | 1,080 |
| `hook_all_methods(class, name, ...)` | every overload of a name | 135 | 928 |
| `hook_all_constructors(class, ...)` | every constructor | 24 | 30 |
| ZwyLib `HookUtils.hook_before/after/replace` | one method object | 5 / 3 / 1 | 13 |

Phases per use: before only 768, after only 749, both 457, replace 43 (2 of them with a before phase as well), callback not resolved 34. Argument types are given for 520 uses (the rest hook by name or by a loop over declared methods). `priority` is passed in 135 uses (26 plugins); hook filters are used in 103 uses (10 plugins), 7 plugins with MVEL `HookFilter.Condition`.

How the class is obtained, per use: a string that reaches `find_class`/`jclass`/`forName` through variables, parameters or tables 1,034; a literal string at the lookup call 824; an imported class 126; the class of an instance the analysis could type (`getParentActivity()`, `X.getInstance()`) 24; unresolved 43.

By package: `org.telegram.ui` outside Components/Cells/ActionBar 255 targets (139 plugins), `org.telegram.ui.Components` 324 (87), `org.telegram.messenger` 157 (101), `org.telegram.ui.Cells` 109 (47), `org.telegram.ui.ActionBar` 64 (34), `android.*` 60 (29), `com.exteragram.*` outside the plugin system 77 (26), `com.exteragram.messenger.plugins` 56 (20), `org.telegram.tgnet` 13 (8), other 47 (10).

By surface (what part of the client the class belongs to): views 643 targets (161 plugins), screens (activities, fragments) 193 (125), model and configuration 77 (61), account controllers and network 76 (52), media 58 (24), the plugin system itself 56 (20), Android OS 51 (15), notifications 9 (13).

### Most hooked classes

`o.t.` is `org.telegram.`, `c.e.m.` is `com.exteragram.messenger.`.

| Android class | plugins | distinct methods | most hooked methods (plugins) |
|---|---|---|---|
| `o.t.ui.LaunchActivity` | 45 | 14 | onActivityResult (25), onResume (8), handleIntent (8), onPause (4), onCreate (3) |
| `o.t.ui.ChatActivity` | 42 | 46 | onResume (16), createView (15), processSelectedOption (5), onPause (5), onFragmentCreate (4) |
| `o.t.ui.Cells.ChatMessageCell` | 30 | 40 | setMessageObject (9), setMessageContent (7), onTouchEvent (3), onAttachedToWindow (3) |
| `o.t.ui.DialogsActivity` | 25 | 31 | onResume (16), createView (11), onFragmentDestroy (4), showSearch (3), getDialogsArray (3) |
| `o.t.messenger.MessagesController` | 18 | 28 | updateInterfaceWithMessages (2), premiumFeaturesBlocked (2), openByUserName (2) |
| `o.t.messenger.MediaController` | 16 | 17 | playMessage (11), cleanupPlayer (6), playPreviousMessage (3), pauseMessage (3) |
| `o.t.messenger.SendMessagesHelper` | 16 | 5 | sendMessage (10), prepareSendingBotContextResult (3), sendReaction (2) |
| `o.t.messenger.AndroidUtilities` | 14 | 8 | openForView (8), updateViewVisibilityAnimated (2), openDocument (2) |
| `o.t.ui.Components.AudioPlayerAlert` | 12 | 8 | constructor (10), updateTitle (9), onSubItemClick (8) |
| `o.t.ui.ProfileActivity` | 12 | 13 | updateRowsIds (6), onResume (4), onFragmentDestroy (4) |
| `o.t.messenger.MediaDataController` | 12 | 10 | loadMedia (4), setPlaceholderImageByIndex (3), addRecentSticker (2) |
| `o.t.ui.Cells.DialogCell` | 11 | 15 | onDraw (7), update (3), isOnline (2), buildLayout (2) |
| `o.t.ui.Components.ChatActivityEnterView` | 11 | 28 | checkSendButton (3), constructor (3), setReplyingMessageObject (2) |
| `o.t.ui.PhotoViewer` | 10 | 9 | setParentActivity (3), openPhoto (2) |
| `o.t.messenger.browser.Browser` | 8 | 3 | openUrl (8), openUrlInSystemBrowser (2) |
| `c.e.m.plugins.ui.PluginSettingsActivity` | 8 | 2 | fillItems (7), createView (2) |
| `o.t.messenger.NotificationsController` | 8 | 4 | processNewMessages (6) |
| `o.t.ui.MainTabsActivity` | 8 | 9 | onResume (5), createView (5) |
| `o.t.messenger.MessageObject` | 8 | 7 | updateTranslation (2), generateCaption (2), applyEntities (2) |
| `o.t.ui.ActionBar.BaseFragment` | 8 | 9 | onResume (2), onBecomeFullyVisible (2) |

### Top targets

Category letters are defined in the next section; the mix counts uses. The last column is the host hook point proposed below (`—` means none).

| # | Android target | plugins | before / after / replace | category mix (uses) | host hook point |
|---|---|---|---|---|---|
| 1 | `o.t.ui.LaunchActivity.onActivityResult` | 25 | 13 / 12 / 0 | c:12, d:3, g:13 | `activity.result` |
| 2 | `o.t.ui.ChatActivity.onResume` | 16 | 3 / 15 / 0 | c:4, d:13 | `screen.lifecycle` |
| 3 | `o.t.ui.DialogsActivity.onResume` | 16 | 3 / 16 / 0 | c:4, d:13 | `screen.lifecycle` |
| 4 | `o.t.ui.ChatActivity.createView` | 15 | 4 / 15 / 0 | c:2, d:17 | `screen.lifecycle` |
| 5 | `o.t.messenger.MediaController.playMessage` | 11 | 7 / 9 / 0 | a:1, b:1, c:9, e:16 | `player.event` |
| 6 | `o.t.ui.DialogsActivity.createView` | 11 | 2 / 11 / 0 | c:2, d:10 | `screen.lifecycle` |
| 7 | `o.t.messenger.SendMessagesHelper.sendMessage` | 10 | 10 / 1 / 0 | b:2, c:1, e:8 | `message.send` |
| 8 | `o.t.ui.Components.AudioPlayerAlert.<init>` | 10 | 0 / 10 / 0 | c:2, d:9 | `player.menu` |
| 9 | `o.t.ui.Cells.ChatMessageCell.setMessageObject` | 9 | 5 / 8 / 0 | d:10 | `message.display` |
| 10 | `o.t.ui.Components.AudioPlayerAlert.updateTitle` | 9 | 0 / 9 / 0 | c:1, d:8 | `player.menu` |
| 11 | `o.t.messenger.AndroidUtilities.openForView` | 8 | 8 / 0 / 0 | c:1, d:1, e:4, g:4 | `message.open` |
| 12 | `o.t.messenger.browser.Browser.openUrl` | 8 | 7 / 0 / 0 | c:1, e:3, g:5 | `url.open` |
| 13 | `o.t.ui.Components.AudioPlayerAlert.onSubItemClick` | 8 | 8 / 0 / 0 | d:4, f:4 | `player.menu` |
| 14 | `o.t.ui.LaunchActivity.handleIntent` | 8 | 8 / 0 / 0 | d:1, g:7 | `url.open` |
| 15 | `o.t.ui.LaunchActivity.onResume` | 8 | 0 / 8 / 0 | c:5, d:4 | `app.lifecycle` |
| 16 | `c.e.m.plugins.ui.PluginSettingsActivity.fillItems` | 7 | 1 / 7 / 0 | d:7, e:1 | `plugin.settings.items` |
| 17 | `o.t.ui.Cells.ChatMessageCell.setMessageContent` | 7 | 4 / 6 / 0 | d:9 | `message.display` |
| 18 | `o.t.ui.Cells.DialogCell.onDraw` | 7 | 6 / 5 / 0 | d:7 | — |
| 19 | `c.e.m.plugins.ui.components.PluginCell.set` | 6 | 1 / 6 / 0 | c:1, d:2, e:3 | `plugin.settings.items` |
| 20 | `o.t.messenger.MediaController.cleanupPlayer` | 6 | 5 / 2 / 0 | c:3, e:4 | `player.event` |
| 21 | `o.t.messenger.NotificationsController.processNewMessages` | 6 | 3 / 3 / 0 | c:3, e:4 | `notifications.incoming` |
| 22 | `o.t.ui.Components.ItemOptions.show` | 6 | 6 / 1 / 0 | d:7 | — |
| 23 | `o.t.ui.ProfileActivity.updateRowsIds` | 6 | 3 / 6 / 0 | d:6 | — |
| 24 | `o.t.ui.ProfileActivity$ListAdapter.onBindViewHolder` | 6 | 3 / 5 / 0 | d:7 | — |
| 25 | `o.t.messenger.NotificationCenter.postNotificationName` | 5 | 3 / 2 / 0 | c:4, e:1 | `notification.center` |
| 26 | `o.t.ui.Adapters.MentionsAdapter.searchUsernameOrHashtag` | 5 | 5 / 2 / 0 | d:6 | — |
| 27 | `o.t.ui.ChatActivity.onPause` | 5 | 2 / 4 / 0 | c:3, d:2 | `screen.lifecycle` |
| 28 | `o.t.ui.ChatActivity.processSelectedOption` | 5 | 5 / 2 / 0 | d:5 | `chat.message_menu` |
| 29 | `o.t.ui.MainTabsActivity.createView` | 5 | 1 / 5 / 0 | c:1, d:5 | `screen.lifecycle` |
| 30 | `o.t.ui.MainTabsActivity.onResume` | 5 | 1 / 5 / 0 | d:5 | `screen.lifecycle` |
| 31 | `o.t.ui.ProfileActivity$ListAdapter.getItemViewType` | 5 | 5 / 1 / 0 | d:5 | — |
| 32 | `c.e.m.pillstack.ui.pills.weather.WeatherPill.onUpdateData` | 4 | 3 / 1 / 0 | d:5 | — |
| 33 | `c.e.m.pillstack.ui.pills.weather.WeatherPill.setData` | 4 | 3 / 1 / 0 | d:5 | — |
| 34 | `c.e.m.plugins.ui.PluginsActivity.fillItems` | 4 | 3 / 4 / 0 | c:1, e:3 | `plugin.settings.items` |
| 35 | `o.t.messenger.MediaDataController.loadMedia` | 4 | 4 / 2 / 0 | b:1, c:2, e:16 | — |
| 36 | `o.t.messenger.UserConfig.hasPremiumOnAccounts` | 4 | 4 / 0 / 0 | a:3, f:1 | `flag.premium` |
| 37 | `o.t.ui.ActionBar.ActionBarMenuItem.toggleSubMenu` | 4 | 4 / 1 / 0 | d:4 | — |
| 38 | `o.t.ui.ActionBar.ActionBarPopupWindow.showAtLocation` | 4 | 3 / 1 / 0 | d:4 | — |
| 39 | `o.t.ui.ChatActivity.onFragmentCreate` | 4 | 2 / 3 / 0 | a:1, c:1, d:2 | `screen.lifecycle` |
| 40 | `o.t.ui.Components.ScrollSlidingTextTabStrip.addTextTab` | 4 | 4 / 2 / 0 | d:3, f:1 | — |
| 41 | `o.t.ui.DialogsActivity.onFragmentDestroy` | 4 | 3 / 3 / 0 | c:1, d:3 | `screen.lifecycle` |
| 42 | `o.t.ui.LaunchActivity.onPause` | 4 | 1 / 3 / 0 | c:3, d:1 | `app.lifecycle` |
| 43 | `o.t.ui.MessageSendPreview.setItemOptions` | 4 | 3 / 1 / 0 | d:4 | — |
| 44 | `o.t.ui.ProfileActivity.onFragmentDestroy` | 4 | 3 / 2 / 0 | c:1, d:3 | `screen.lifecycle` |

## Categories: what the host would have to expose

Each use gets a surface (from the class) and a contract (from the callback), combined into one category. A use lands in the worst category any of its callbacks needs.

| | Category | Meaning | plugins | targets | uses | plugins complete if only this is supported | of those, no other blocker |
|---|---|---|---|---|---|---|---|
| a | static override | Sets or returns a constant, or a value computed without reading `thisObject`, `args` or the result: a flag, a limit, a disabled method | 41 | 98 | 112 | 15 | 6 |
| b | asynchronous flow | Modifies or cancels inside account, network, notification or player code, which runs asynchronously on iOS | 27 | 39 | 50 | 2 | 1 |
| c | event | Observes; reads nothing, or only identifiers and data objects | 76 | 167 | 240 | 15 | 1 |
| d | view | Calls view or canvas members on hooked objects, reflects into a UI object, or hooks draw/layout/measure/touch/bind methods | 191 | 701 | 1,136 | 87 | 7 |
| e | internals | Calls or reflects into a non-UI Android object (a controller singleton, the player) beyond what the Python-local facades provide | 62 | 122 | 254 | 16 | 3 |
| f | synchronous decision | Result of a getter, predicate or formatter that depends on its arguments or receiver | 36 | 67 | 112 | 5 | 2 |
| g | deferrable action | Cancels or rewrites a discrete user action or screen call (open a URL, a file, an intent, start a call) | 33 | 34 | 61 | 8 | 0 |
| h | Android OS | Hook of an `android.*`/`java.*` class outside the view system | 11 | 31 | 42 | 2 | 1 |
| x | unresolved | Class or method not statically resolvable | 23 | 21 | 44 | 4 | 0 |

Of the 1,136 view uses, 264 (75 plugins, 167 targets) hook draw, layout, measure, touch, attach or adapter-bind methods; the other 872 are lifecycle or setter hooks whose callback reaches into the view tree (`getFragmentView()`, `addView`, `getActionBar().createMenu()`, private view fields).

### Cumulative curves

Whole categories, best order by plugins that become hook-complete (all their hook uses covered), with the number that would then pass preflight entirely under the what-if host:

| add category | hook-complete | pass preflight | pass ignoring `MEMBER`/unprovided-member blockers |
|---|---|---|---|
| d view | 87 | 7 | 12 |
| + c event | 123 | 9 | 21 |
| + e internals | 159 | 12 | 28 |
| + a static override | 184 | 20 | 39 |
| + f synchronous decision | 206 | 22 | 42 |
| + g deferrable action | 226 | 22 | 42 |
| + b asynchronous flow | 249 | 23 | 45 |
| + h Android OS | 259 | 24 | 46 |

The order is dominated by the view category, which is the one iOS cannot offer. Restricted to the contracts iOS can serve (a, b, c, g), 44 plugins are eligible and they need 75 distinct targets; greedy order by newly completed plugins:

| step | Android target | new | hook-complete | pass preflight |
|---|---|---|---|---|
| 1 | `LaunchActivity.onActivityResult` | 8 | 8 | 0 |
| 2 | `LaunchActivity.handleIntent` | 1 | 9 | 0 |
| 3 | `Browser.openUrl` | 2 | 11 | 0 |
| 4 | `MediaController.playMessage` | 1 | 12 | 1 |
| 5 | `VoIPHelper.startCall` | 1 | 13 | 1 |
| 6 | `UserConfig.hasPremiumOnAccounts` | 1 | 14 | 2 |
| 7 | `NotificationsController.processNewMessages` | 1 | 15 | 2 |
| 8 | `PhotoViewer.openPhoto` | 1 | 16 | 2 |
| 9 | `ChatActivity.onFragmentCreate` | 1 | 17 | 2 |
| 10 | `ArticleViewer$WindowView.handleTouchEvent` | 1 | 18 | 2 |
| 11 | `Theme.applyDayNightThemeMaybe` | 1 | 19 | 3 |
| 12 | `BaseFragment.onActivityResultFragment` | 1 | 20 | 3 |
| 13 | `BaseFragment.isSupportEdgeToEdge` | 1 | 21 | 4 |
| 14 | `SendMessagesHelper.sendReaction` | 1 | 22 | 5 |
| 15 | `SendMessagesHelper.sendMessage` | 1 | 23 | 5 |
| 20 | (five more single-plugin targets) | | 28 | 5 |
| 40 | | | 38 | 8 |
| 75 | (all) | | 44 | 8 |

After the first target the curve gains about one plugin per target: there is no head to exploit. Ignoring the callback contract entirely (every target counted as servable, view hooks included) the curve is 25 plugins after 10 targets, 55 after 40, 94 after 80, 139 after 160, 193 after 320 and 259 after all 1,026 targets of the plugins with fully resolved hooks; the passing counts at those points are 3, 10, 16, 16, 19 and 24.

## How Android implements it

Sources: `plugins-pysdk/src/base_plugin.py`, `TMessagesProj/src/full/java/com/exteragram/messenger/plugins/xposed/{PyMethodHook,PyMethodReplacement}.kt`, `hooks/{HookFilter,XposedHookRecord,HookRecord}.kt`, `PluginsController.kt` at revision b4d852f. The `de.robv.android.xposed` classes come from a dependency that is not in the sparse clone; `MethodHookParam` and priority semantics below are the standard Xposed API and were not read from source.

SDK-visible contract:

- `BasePlugin.hook_method(method_or_constructor, xposed_hook=None, priority=None, *, before=None, after=None, before_filters=None, after_filters=None)` returns an `XC_MethodHook.Unhook` or `None`. `hook_all_methods(hook_class, method_name, ...)` and `hook_all_constructors(hook_class, ...)` take the same options and return a list of `Unhook` or `None` when nothing matched. `unhook_method(unhook)` removes one hook.
- All three are `@final` and return `None` once the plugin's stop event is set. They raise `TypeError` when neither `xposed_hook` nor `before`/`after` is given (`hook_all_methods` also for a `None` name). Every other failure is logged and `None` is returned, so plugins routinely test the return value.
- `xposed_hook` is a `MethodReplacement` (abstract `replace_hooked_method(param)`, its return value becomes the result), a `MethodHook` (`before_hooked_method(param)`, `after_hooked_method(param)`; a phase is installed only when the subclass overrides it), or any object with those method names. When `xposed_hook` is given, `before=`/`after=` are ignored. Without it the callables are wrapped in `BaseHook`, which logs their exceptions.
- `param` is the Xposed `MethodHookParam`: fields `method`, `thisObject`, `args` (writable array); `getResult()`, `setResult(value)` (in a before hook this also skips the original method), `getThrowable()`, `hasThrowable()`, `setThrowable(t)`, `getResultOrThrowable()`, and the extras bundle. Corpus use: `param.args` 217 plugins, `param.thisObject` 213, `setResult` 134, `getResult` 44, `param.method` 24, throwable accessors 3, extras 1, `XposedBridge.invokeOriginalMethod` 1.
- Filters: `@hook_filters(...)` on a callback, or `before_filters=`/`after_filters=`, attach `HookFilter` values (`RESULT_IS_NULL`, `RESULT_IS_TRUE`, `RESULT_IS_FALSE`, `RESULT_NOT_NULL`, `ResultIsInstanceOf`, `ResultEqual`, `ResultNotEqual`, `ArgumentIsNull`, `ArgumentIsTrue`, `ArgumentIsFalse`, `ArgumentNotNull`, `ArgumentIsInstanceOf`, `ArgumentEqual`, `ArgumentNotEqual`, `Condition(mvel, object)`, `Or(...)`). `HookFilter.execute` runs them in Kotlin before Python is entered; all must pass; result filters are false in the before phase; `Condition` evaluates an MVEL expression with `param`, `result`, `object` and the receiver as context.
- `PyMethodHook` skips the callback when the plugin is inactive and catches every exception, so a plugin failure never reaches the app. `PyMethodReplacement` calls the original method when the plugin is inactive and returns `null` when the callback throws.
- Bookkeeping: `PluginsController.addXposedHook(s)` records each `Unhook` per plugin; `cleanupPlugin` unhooks all of them on unload; `hasXposedHook(methodName, classes)` lets app code ask whether a method is hooked.
- The callback runs synchronously on the thread that called the hooked method, which for UI classes is the main thread.

The iOS SDK today (`submodules/AyuPluginBridge/Python/base_plugin.py`, `hook_utils.py`, `_ayu_operations.py`):

| | Android | iOS SDK now |
|---|---|---|
| Entry points | Xposed bridge | `_method_hook` builds a `hooks.register` call with kind `java_method`, `java_all_methods` or `java_all_constructors`; today's host rejects these kinds |
| Naming a target | `Class.getClass().getDeclaredMethod(...)`, loops over `getDeclaredMethods()`, `hook_utils.get_method` | `hook_utils.get_method`/`get_constructor` and ZwyLib finders refuse Python-local classes; a host class has no such members; the in-progress member-level preflight reports `X.getClass` as `MEMBER` |
| Classes | `MethodReplacement(XposedHook)`, abstract | `MethodReplacement(MethodHook)` |
| `xposed_hook` with `before`/`after` | callables ignored | `TypeError` |
| Filters | evaluated natively | data objects exist; any filter raises `UnsupportedAPI` |
| Priority default | Xposed default | 0 |
| Return value | `Unhook`, list, or `None` on failure | a `Registration`; failures raise |
| Preflight | — | `hook_method()`, `hook_all_methods()`, `hook_all_constructors()` and ZwyLib `HookUtils` are `OPERATION hooks.java_method`; partial hooks are `hooks.partial` |

`Sources/AyuBridgeHooks.swift` already declares typed hook points (`message.send.pre`, `chat.did_open`, `app.did_become_active`, ...) with a `publish` function, but a search finds no publication site in the app outside the module. The asynchronous hook chain being added in `Integration/AyuPluginTelegramHooks.swift` (ordered participants, bounded wait, decision per step) is the mechanism this design reuses.

## iOS feasibility

### The performance invariant decides the shape

Main never waits for Python, and there are no synchronous main-to-Python calls. A Xposed callback is exactly such a call. Each category therefore needs a different mechanism:

| Category | Mechanism | Verdict |
|---|---|---|
| a static override | The SDK evaluates the callback on the Python queue ahead of time and pushes the value; the host reads a snapshot | Servable. Semantics change from per-call to cached; only callbacks that are statically pure qualify |
| b asynchronous flow | The flow is already a signal or queue hop on iOS; the host suspends it, asks the plugins in priority order and continues, with the 2-second bound of `protocol-telegram.md` | Servable where the flow has a single entry point |
| c event | Fire-and-forget notification with a typed payload | Servable. `setResult` and argument writes must raise |
| g deferrable action | The action starts on main; the host parks it, asks the plugins asynchronously, then continues or drops it. Main keeps running; only that action is delayed | Servable for discrete user actions, not for anything a frame depends on |
| f synchronous decision | Would need a precomputed table over an enumerable argument domain, or an ask-then-refresh cache | Fail closed. No general mechanism; 36 plugins |
| e internals | Depends on the member: provided by a Python-local facade or not | Fail closed per member |
| d view | No Android view tree or canvas exists; draw/layout hooks would be per-frame Python calls | Not mappable. 191 plugins |
| h Android OS, x unresolved | — | Not mappable. 11 and 23 plugins |

### Proposed host hook points and their iOS locations

Paths are relative to the repository root. "Plugins served" counts plugins all of whose uses of that point have a contract the point serves.

| Stage | Host hook point | Android targets (signature, semantics) | Nearest iOS point | Plugins using / served | What the callback can get, and what is lost |
|---|---|---|---|---|---|
| 1 | `activity.result` | `LaunchActivity.onActivityResult(int requestCode, int resultCode, Intent data)` (protected void; delivers the result of `startActivityForResult`, in the corpus almost always a file or image picker); `BaseFragment.onActivityResultFragment` | Bridge-owned. The bridge's own `startActivityForResult` adapter presents `UIDocumentPickerViewController` (as `submodules/AyuPluginBridge/Integration/AyuPluginManagerViewController.swift:217` does) or `legacyICloudFilePicker` (`submodules/LegacyMediaPickerUI/Sources/LegacyICloudFilePicker.swift:154`) and raises the point itself | 26 / 22 | Request code, result code, an `Intent` whose `getData()`/`getClipData()` name files copied into the app container; `getContentResolver().openInputStream(uri)` over those files. Lost: results of intents the bridge did not start, persistable URI permissions, content providers |
| 1 | `app.lifecycle` | `LaunchActivity.onResume()`, `onPause()`, `onCreate(Bundle)`, `onStart`, `onStop`, `onDestroy` | `AyuPluginService.applicationDidChange` (`submodules/AyuPluginBridge/Integration/AyuPluginService.swift:755`), fed by `submodules/TelegramUI/Sources/AyuPluginApplicationBinding.swift:104` | 11 / 5 | The event. Lost: the activity as a view root (`getWindow().getDecorView()`); 11 of the 20 uses are view uses |
| 1 | `message.send` | `SendMessagesHelper.sendMessage(SendMessageParams)` (void; Android itself calls the plugin send hook here) and its forwarding overloads `sendMessage(ArrayList<MessageObject>, long peer, ...)` | `ChatControllerImpl.sendMessages` (`submodules/TelegramUI/Sources/ChatController.swift:9448`), already routed through `AyuPluginService.applySendHooks`; typed form `telegram.hooks.send_message` | 10 / 3 | A `SendMessageParams` with the fields of `protocol-telegram.md`; cancel and modify. Lost: forwards, fields outside the contract, reflection into the helper. 8 of the 11 uses touch members no facade provides |
| 1 | `plugins.state` | `PluginsController.setPluginEnabled`, `deletePlugin`, `loadPluginFromFile`, `clearPluginSettingsPreferences`; engine `loadPlugin`, `setPluginEnabled` | Bridge-owned: `AyuPluginService` enable, disable and delete | 4 / 2 | Plugin id and new state, after the fact. A before hook that vetoes disabling or deleting a plugin must not be served |
| 1 | `request.send`, `updates.process` | `ConnectionsManager.sendRequest(...)`; `MessagesController.processUpdateArray(ArrayList<Update>, users, chats, fromGetDifference, date)` | `Network.request` (`submodules/TelegramCore/Sources/Network/Network.swift:1440`) and `AccountStateManager.addUpdates` (`submodules/TelegramCore/Sources/State/AccountStateManager.swift:452`) through `AyuPluginTelegramHooks.interceptRequest`/`interceptUpdates` | 2 / 1, 1 / 1 | TL objects, as the existing `telegram.hooks.set` contract. A wildcard subscription serializes every request and update |
| 2 | `screen.lifecycle` | `ChatActivity`, `DialogsActivity`, `ProfileActivity`, `TopicsFragment`, `MainTabsActivity`, `BaseFragment`: `onResume()`, `onPause()`, `createView(Context) -> View`, `onFragmentCreate() -> boolean`, `onFragmentDestroy()`, `onBecomeFullyVisible()`, transition callbacks | `ChatControllerImpl.loadDisplayNode`/`viewDidAppear`/`viewWillDisappear` (`submodules/TelegramUI/Sources/ChatController.swift:7905`, `8091`, `8543`); `ChatListControllerImpl` (`submodules/ChatListUI/Sources/ChatListController.swift:1413`, `2512`, `3004`); `PeerInfoScreenImpl` (`submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift:7390`, `7226`) | 48 / 5 | The screen snapshot of `telegram.screen` (kind, account, dialog id, topic, mode) behind a fragment facade with a stable identity per screen. Lost: the fragment's views; `createView`'s result; a before hook cannot block the screen. 111 of the 144 uses are view uses |
| 2 | `url.open` | `Browser.openUrl(Context, String or Uri[, allowCustom, tryTelegraph])` (static void); `LaunchActivity.handleIntent(Intent, isNew, restore, fromPassword, ...) -> boolean` (private; routes every incoming intent and deep link); `onNewIntent`, `runLinkRequest`, `openTelegramUrl`; `AndroidUtilities.openUrl` | `openExternalUrlImpl` (`submodules/TelegramUI/Sources/OpenUrl.swift:359`), `AppDelegate.openUrl` (`submodules/TelegramUI/Sources/AppDelegate.swift:2745`), `openResolvedUrlImpl` (`submodules/TelegramUI/Sources/OpenResolvedUrl.swift:65`) | 13 / 8 | The URL string (as an `Intent` or `Uri` facade where Android passes one); consume or replace. Lost: the other `handleIntent` arguments, non-URL intents, the `Context` |
| 2 | `message.open` | `AndroidUtilities.openForView(MessageObject or File or Document, Activity, ...) -> boolean` (static; opens a file with the system viewer); `openDocument`; `PhotoViewer.openPhoto(MessageObject, ...) -> boolean` | `openChatMessageImpl` (`submodules/TelegramUI/Sources/OpenChatMessage.swift:35`) behind `SharedAccountContextImpl.openChatMessage` (`submodules/TelegramUI/Sources/SharedAccountContext.swift:2064`) | 10 / 5 | The message as a `MessageObject`, file name, MIME type, local path when downloaded; consume. Lost: the `File`-only overload, the photo viewer object |
| 2 | `player.event` | `MediaController.playMessage(MessageObject[, boolean silent]) -> boolean`, `pauseMessage(MessageObject[, smoothFade]) -> boolean`, `cleanupPlayer(notify, stopService[, byVoiceEnd, transfer])`, `playNextMessage()`, `playPreviousMessage()`, `stopAudio`, `seekToProgress`, `setPlaylist` | `MediaManagerImpl.globalMediaPlayerState` and `setPlaylist` (`submodules/TelegramUI/Sources/MediaManager.swift:144`, `485`), `SharedMediaPlayer` (`submodules/TelegramUI/Sources/SharedMediaPlayer.swift:113`) | 13 / 5 | Event name and the playing message. Lost: vetoing playback, the playlist, private player fields. 60 of the 85 uses reflect into `MediaController` or call members no facade provides |
| 2 | `notifications.incoming` | `NotificationsController.processNewMessages(ArrayList<MessageObject>, isLast, isFcm, CountDownLatch)`, `showNotifications()` | `AccountStateManager.notificationMessages` (`submodules/TelegramCore/Sources/State/AccountStateManager.swift:961`), consumed in `submodules/TelegramUI/Sources/ApplicationContext.swift:303` and by `SharedNotificationManager` (`submodules/TelegramUI/Sources/SharedNotificationManager.swift:32`) | 6 / 3 | The new messages as a mutable list; removing entries suppresses their notification. Lost: push-only notifications handled by the extension process |
| 2 | `notification.center` | `NotificationCenter.postNotificationName(int id, Object... args)` (the app's event bus) | The bridge's existing NotificationCenter observer adapter | 5 / 4 | Only the ids that adapter already maps; no interception |
| 2 | `call.start` | `VoIPHelper.startCall(User, videoCall, canVideoCall, Activity, UserFull, AccountInstance[, confirmed])` (static void), `showGroupCallAlert`, `joinGroupCall` | `PresentationCallManagerImpl.requestCall` (`submodules/TelegramCallsUI/Sources/PresentationCallManager.swift:430`) | 3 / 3 | The peer as a TL user and the video flag; veto. Group calls take another path that was not traced |
| 2 | `reaction.send` | `SendMessagesHelper.sendReaction(MessageObject, ArrayList<VisibleReaction>, VisibleReaction added, big, addToRecent, BaseFragment, Runnable)` | `updateMessageReactionsInteractively` (`submodules/TelegramCore/Sources/State/MessageReactions.swift:24`) | 2 / 2 | Message, reactions, the `big` flag as a writable argument |
| 2 | `peers.updated` | `MessagesController.putUser(User, fromCache[, force]) -> boolean`, `putUsers`, `putChat`, `putChats` | `updatePeers(transaction:accountPeerId:peers:)` (`submodules/TelegramCore/Sources/UpdatePeers.swift:142`) | 1 / 1 | TL users and chats after they are stored. Hot path: every peer update would be serialized |
| 2 | `flag.premium` | `UserConfig.isPremium() -> boolean`, static `UserConfig.hasPremiumOnAccounts() -> boolean` (any signed-in account is premium), `MessagesController.premiumFeaturesBlocked() -> boolean` | No single getter. Premium is read from the peer (`TelegramUser.isPremium`, `submodules/TelegramCore/Sources/Utils/PeerUtils.swift:253`, `submodules/TelegramCore/Sources/TelegramEngine/Peers/Peer.swift:516`) at many call sites and from `PremiumConfiguration` (`submodules/AccountContext/Sources/Premium.swift:157`); the account limit is the constant `maximumNumberOfAccounts` (`submodules/AccountUtils/Sources/AccountUtils.swift:10`) | 4 / 3 | A boolean. What the override changes on iOS is a product decision per feature, not one switch |
| 2 | `flag.round_video` | `SystemUtils.getRoundVideoResolution() -> int`, `getRoundVideoBitrate()`, `getRoundAudioBitrate()`, `getRoundVideoMaxDurationMs()` (exteraGram) | `submodules/TelegramUI/Components/VideoMessageCameraScreen`; the recording constants were not located | 3 / 2 | Integers read when recording starts |
| 3 | `chat.message_menu` | `ChatActivity.fillMessageMenu(MessageObject primaryMessage, ArrayList<Integer> icons, ArrayList<CharSequence> items, ArrayList<Integer> options)`; `processSelectedOption(int option)` | `contextMenuForChatPresentationInterfaceState` (`submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift:495`) through the existing `submodules/TelegramUI/Sources/Chat/AyuPluginMessageContextMenu.swift` | 6 / 1 | The three lists as Python-local `ArrayList`s the callback appends to; the option id on tap. Callbacks also call `closeMenu`, read `selectedObject` and other fragment fields |
| 3 | `player.menu` | `AudioPlayerAlert(Context, ResourcesProvider)` constructor, `updateTitle(boolean shutdown)`, `onSubItemClick(int id)` (all three hooked together to add entries to the audio player's menu) | `OverlayAudioPlayerControllerNode` (`submodules/TelegramUI/Sources/OverlayAudioPlayerControllerNode.swift:22`) | 11 / 1 | A menu facade recording `addSubItem(id, icon, text)`; the id on tap. 21 of the 29 uses also touch other views of the sheet |
| 3 | `plugin.settings.items` | `PluginSettingsActivity.fillItems(ArrayList<UItem>, UniversalAdapter)`, `PluginsActivity.fillItems`, `PluginCell.set(Plugin, PluginCellDelegate)` | Bridge-owned manager and settings screens (`submodules/AyuPluginBridge/Integration/AyuPluginManagerViewController.swift`) | 15 / 1 | The row list. Callbacks build custom Android views for rows |
| 3 | `message.display` | `ChatMessageCell.setMessageObject(MessageObject, GroupedMessages, bottomNear, topNear, firstInChat, lastInChatList)`, private `setMessageContent(...)`; `MessageObject.applyEntities`, `generateCaption`, `updateTranslation` | Chat history entry preparation (`submodules/TelegramUI/Sources/ChatHistoryEntriesForView.swift`); the cell (`submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift`) lays out off the main thread on every pass and cannot call Python | 18 / 0 | Only a cached, asynchronously computed replacement of text and entities per message. All 30 uses touch the cell or need more |

Top targets with no proposed point, and why:

| Android target | Android semantics | Nearest iOS code | Why not |
|---|---|---|---|
| `DialogCell.onDraw(Canvas)` (7) | Draws one chat-list row | `submodules/ChatListUI/Sources/Node/ChatListItem.swift` | Rows are layer trees laid out asynchronously; there is no canvas pass to hook, and a per-row Python call breaks the invariant |
| `ItemOptions.show()` (6), `ActionBarPopupWindow.showAtLocation` (4), `ActionBarMenuItem.toggleSubMenu` (4), `MessageSendPreview.setItemOptions` (4) | Generic popup menus; callbacks add or restyle entries of whatever menu is shown | `submodules/ContextUI/Sources/ContextController.swift`, `submodules/TelegramUI/Components/ContextControllerImpl` | No shared identity of "which menu" between the clients; specific menus need their own menu type in `menus.add` |
| `ProfileActivity.updateRowsIds()` (6), `ProfileActivity$ListAdapter.onBindViewHolder` (6), `getItemViewType` (5) | Row-index table and adapter of the profile screen; plugins insert rows by reflection | `PeerInfoScreen` item builders | No row-id table exists; adding profile rows is a new API, not a mapping |
| `MentionsAdapter.searchUsernameOrHashtag(CharSequence, int, ArrayList<MessageObject>, usernameOnly, forSearch)` (5) | Computes inline suggestions for the text at the caret | `submodules/TelegramUI/Sources/ChatInterfaceInputContexts.swift` | The iOS side is an asynchronous signal and could carry a chain point, but all 6 uses reach into the adapter |
| `ScrollSlidingTextTabStrip.addTextTab(int, CharSequence)` (4), `MediaDataController.loadMedia(...)` (4) | Shared-media tabs and their loader | Profile media panes | Tab identity and loader arguments have no counterpart; 16 of 19 `loadMedia` uses reflect into the controller |
| `WeatherPill.*`, `MusicPlayerSheet.*` and other `com.exteragram.*` classes outside the plugin system (77 targets, 26 plugins) | Mostly exteraGram-only features | none | The feature does not exist on iOS |

## Proposal for `hooks.java_method`

`hooks.java_method` stays a reserved name that no host declares: it is what preflight reports for a target without a mapping. Mapped targets are served through one host operation per hook point, declared only when that point is implemented exactly as specified, as the existing rule for operations requires.

### Table

A Python table in the SDK (proposed `Python/_ayu_xposed.py`) is the single source for registration, reflection and preflight:

```
(android class, method, signature or ANY) -> HookPoint(
    name,             # "activity.result"; the host operation is "hooks.point.<name>"
    kind,             # "event" | "chain" | "override"
    phases,           # subset of before, after, replace the point can honour
    this,             # Python-local class of param.thisObject, or None for a static method
    args,             # payload field per Java argument, with its Python-local class
    result,           # Java return type, and whether a hook may set it
    this_members,     # members of thisObject the facade provides (for preflight)
)
```

The host never sees Android names, as with TL constructor ids: it implements named points with typed payloads, and the SDK owns the Android side.

### Naming a target (Python only, no host)

Python-local facade classes gain the reflection that plugins use to name a target: `X.getClass()`, `getDeclaredMethod(name, *types)`, `getMethod`, `getDeclaredMethods()`, `getDeclaredConstructor(s)`, `hook_utils.get_method`/`get_constructor`, and the ZwyLib finders return a member descriptor (class, name, signature, kind) with `getName()`, `getParameterTypes()`, `getParameterCount()`, `getDeclaringClass()` and a no-op `setAccessible()`. `getDeclaredMethods()` lists the members the table knows for that class. A lookup of an unmapped member raises `UnsupportedAPI` (also a `NoSuchMethodException`, so Android-style `except` clauses behave as on a client build without that method) and is recorded, so that a plugin which swallowed the error is shown as degraded with the list of hooks it did not get, not as working.

### Registration and callbacks

`hook_method`, `hook_all_methods` and `hook_all_constructors` resolve their target through the table and call `hooks.point.<name>` with `{phases, priority, callback}`; the result is a token for `hooks.unregister`, wrapped in an `Unhook`-shaped object (`unhook()`, `getHookedMethod()`). `hook_all_methods` returns a list with one entry per mapped overload. Registrations belong to the plugin generation and are removed by `plugin.deactivate`; 256 per generation is enough (the corpus maximum is 108 call sites in one plugin).

Per kind:

- `event`: the host sends the payload after the fact; the callback's result is ignored. `setResult`, `setThrowable` and writes to `args` raise `UnsupportedAPI`, since the point cannot honour them.
- `chain`: the host parks the flow or the user action and calls the plugins in descending priority (ties by plugin id), each once, with the bounds and failure rule of the TL hooks (2 seconds, then continue unchanged). The answer is `{skip: bool, result?, args?}`: a before hook that called `setResult` skips the original and the remaining before hooks, as Xposed does; changed arguments are validated by the host and discarded when invalid. After hooks run in ascending priority and may replace the result where the point says so.
- `override`: no callback at call time. The SDK runs the callback on the Python queue at registration, after every `set_setting` of that plugin and on app resume, with a probe `param` whose `thisObject` and `args` raise. If the callback called `setResult(v)` (or a replacement returned `v`), the SDK pushes `{value: v}` with `hooks.override.<name>`, otherwise it clears the override. The host reads the last pushed value synchronously. The callback therefore runs at different times than on Android; only callbacks that preflight finds pure (constants, `get_setting`, logging) are admitted.

`param` is a Python class with Android's members: `thisObject`, `args` (a list whose writes are tracked), `method` (the descriptor), `getResult`, `setResult`, `getThrowable`, `hasThrowable`, `setThrowable`, `getResultOrThrowable`. The point's adapter builds `thisObject` and `args` from the payload with the existing Python-local classes: TL values through `telegram_tl.from_bridge`, messages as `MessageObject(account, message, ...)`, send parameters through `SendMessageParams._ayu_from_wire`, screens as the fragment classes over the `telegram.screen` snapshot, intents and URIs as local `Intent`/`Uri` objects. The host includes a stable instance id for objects with identity (a screen, the player); the SDK keeps one facade per id, because callbacks compare and cache hooked objects by identity. A member the facade lacks raises `UnsupportedAPI` (also `AttributeError`), which is already the rule for Python-local classes.

Filters: argument and result filters and `Or` are evaluated in Python before the callback, on the synthesized `param`. `HookFilter.Condition` needs an MVEL interpreter and stays unsupported, as MVEL menu conditions are. Argument filters on an `override` point are refused.

Not reproduced on any point: running on the caller's thread, `XposedBridge.invokeOriginalMethod` and `param.method.invoke`, private fields beyond a facade's declared ones, hooks installed on the class of a live object, and any hook the table does not list.

### Preflight per target

Static inspection resolves each hook call the way `inventory.py` does, and follows `param` through the callback the way `_ayu_inspection.send_hook_fields` already follows send-hook parameters:

| Finding | Result |
|---|---|
| Target resolved, mapped, point declared by the host, callback within the point's contract | no blocker |
| Target resolved, mapped, point not declared | `OPERATION hooks.point.<name> (Class.method)` |
| Target resolved, not in the table | `OPERATION hooks.java_method (Class.method)` |
| Target not resolvable (computed name, class of a live object) | `OPERATION hooks.java_method (unresolved target)` |
| Callback sets a result or writes arguments on an `event` point, reads the call on an `override` point, or uses a phase the point lacks | `OPERATION hooks.java_method (Class.method: <phase or member>)` |
| Callback uses a `thisObject`/argument member outside the facade, or passes the object to code inspection cannot follow | `OPERATION hooks.java_method (Class.method: <member>)` |
| `HookFilter.Condition` | `OPERATION hooks.java_method (MVEL filter)` |

A hook that inspection cannot prove is a blocker. Packages (`.elyx`, `.eaf`) get the strict result, as for the send hook.

### Stages

Counts are plugins whose every hook call is served (hook-complete), then those with no other preflight blocker under the what-if host.

| Stage | Content | Points (Android targets) | Plugins touched | Hook-complete | Pass preflight |
|---|---|---|---|---|---|
| 0 | SDK only: table, member descriptors, `param`, filters, the per-target preflight above | — | — | 0 | 0 |
| 1 | Points the bridge owns or that ride on operations already specified: `activity.result` (with the picker behind `startActivityForResult`), `app.lifecycle`, `plugins.state`, `message.send`, `request.send`, `updates.process` | 6 (24) | 51 | 12 | 0 |
| 2 | New call sites in the app: `screen.lifecycle`, `url.open`, `message.open`, `player.event`, `notifications.incoming`, `notification.center`, `call.start`, `reaction.send`, `peers.updated`, and the override mechanism with `flag.premium`, `flag.round_video` | 17 (98) | 124 | 26 | 4 |
| 3 | Bespoke facades over UI structure: `chat.message_menu`, `player.menu`, `plugin.settings.items`, `message.display` | 21 (124) | 151 | 26; 36 only if each facade covered everything its callbacks touch, which was not verified | 4 |

Stage 0 by itself changes no pass count but replaces the single `hooks.java_method (hook_method())` blocker by one blocker per target, which is what makes the remaining work measurable in the meter.

The 12 plugins of stage 1 still have between 5 and 35 other blockers each (classes such as `android.app.Activity`, `BitmapFactory`, `MediaPlayer`, `WebView`, and unprovided members). The 4 plugins that pass after stage 2 are the ones served by `flag.premium` (2), `reaction.send` (1) and `player.event` (1); they have no other blocker today.

## Ceiling and what else blocks

Other blockers of the 282 hook-using plugins under the what-if host, hooks and the reflection used to name targets excluded: `CLASS` 233 plugins (548 distinct classes; most frequent `Bitmap` 43, `BitmapFactory` 32, `BackupImageView` 28, `ImageLocation` 24, `BottomSheet` 23, `MediaDataController` 23, `BitmapDrawable` 21, `UItem` 21, `ChatMessageCell` 21), `OPERATION` 151 (`sdk.unprovided_member`, 2 `telegram.stickers`), `MEMBER` 86, `DEPENDENCY` 27, `IMPORT` 10, `SDK_MEMBER` 9, `REQUIREMENT` 7, `VERSION_POLICY` 1.

The 24 plugins blocked by hooks alone split, by their worst hook category, into view 10, static override 6, internals 3, synchronous decision 2, asynchronous flow 1, event 1, Android OS 1. Only the static-override, flow and event ones (8) can be reached by a mapping, and 4 of those 8 hook targets for which no point is proposed (an edge-to-edge predicate, a touch predicate of the message cell, an exteraGram ad controller, the automatic day/night theme switch).

Realistic ceiling, then: about 26 to 44 hook-complete plugins out of 282 depending on how many of the 75 long-tail targets are worth a point each, and 4 to 8 plugins that pass preflight because of the mapping. The other gains require work outside hooks (classes, members, view adapters).

Not mappable in principle: 191 plugins with view hooks (1,136 uses on 701 targets), 11 with Android-OS hooks, 23 with unresolvable targets; 204 plugins have at least one of these. A further 36 plugins need synchronous argument-dependent results and 62 reach into controller internals; both fail closed unless a specific point is designed for a specific target.

## Not determined

- The true error rate of the classification, and how many of the 1,162 targets are artefacts of uncorrelated loops.
- Whether the callbacks counted as served stay inside what a facade would provide at member level; this needs member-level preflight or a per-plugin review.
- The iOS call sites for group calls, round-video recording constants and the push-notification extension path.
- Whether a local premium override is wanted at all, and which iOS behaviours it should change.
- Xposed's `MethodHookParam` and priority semantics were taken from the public API, not from source in the clone.
- None of the iOS locations was compiled against or exercised; they are the nearest symbols found by reading.

## Reproducing

From the repository root, in this order (each script documents its inputs and outputs; none executes plugin code):

```sh
S=/Users/toby/work/_refs/plugin-bridge-scratch/xposed
python3 -X utf8 -B $S/inventory.py     # plugins/*.plugin -> inventory.json
python3 -X utf8 -B $S/classify.py      # -> classified.json, category table
python3 -X utf8 -B $S/blockers.py      # what-if preflight per plugin -> blockers.json
python3 -X utf8 -B $S/curve.py         # mapping.py + the above -> targets.json, curve.json, curves and stages
python3 -X utf8 -B $S/tables.py        # Markdown fragments for the tables above
python3 -X utf8 -B $S/unresolved.py    # the unresolved call sites
```

`run.sh` in that directory runs the first four. `mapping.py` holds the proposed points and the Android-to-point rules; editing it and rerunning `curve.py` recomputes the stage numbers.
