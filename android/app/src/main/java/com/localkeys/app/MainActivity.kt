package com.localkeys.app

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.util.TypedValue
import android.view.ContextThemeWrapper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.widget.Button
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.Switch
import android.widget.TextView
import android.window.OnBackInvokedDispatcher
import kotlin.math.roundToInt

class MainActivity : Activity() {
    private lateinit var keyboard: KeyboardView
    private lateinit var flight: FlightView
    private lateinit var bar: LinearLayout
    private lateinit var dot: View
    private lateinit var status: TextView
    private lateinit var langBtn: TextView
    private lateinit var textBtn: TextView
    private lateinit var menuBtn: TextView
    private lateinit var hideBtn: TextView
    private lateinit var pairing: TextView
    private lateinit var banner: TextView
    private val dp by lazy { resources.displayMetrics.density }

    private val onConn: () -> Unit = { updateStatus() }
    private val onLegends: () -> Unit = { keyboard.updateLegends(); flight.updatePcStatus() }
    private val onInput: () -> Unit = { keyboard.onInputState() }
    private val onStall: () -> Unit = { releaseAllInputs() }
    private val onLinkReady: () -> Unit = { FlightController.engine.resendVjoyIfUsed() }

    private fun isMsfs() = Presets.byId(Settings.presetId).kind == PresetKind.MSFS

    private fun releaseAllInputs() {
        keyboard.releaseAllTouches()
        flight.releaseAllTouches()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Settings.init(this)
        ConnectionManager.init(this)
        FlightController.init(this)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        keyboard = KeyboardView(this)
        keyboard.onMenu = { showSettings() }
        keyboard.onSpecial = { if (it == Special.TEXT_PANEL) showTextPanel() }

        flight = FlightView(this)
        flight.onMenu = { showSettings() }

        bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding((8 * dp).toInt(), 0, (12 * dp).toInt(), 0)
        }
        dot = View(this)
        status = TextView(this).apply {
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            isSingleLine = true
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        langBtn = pill("—") { showLangMenu() }
        textBtn = pill("Аа") { showTextPanel() }
        menuBtn = pill("Меню") { showSettings() }
        hideBtn = pill("Скрыть ▴") { hideTopBar() }
        // Buttons on the left, over Esc / digits: far from Backspace, which sits under the right end.
        for (b in listOf(menuBtn, textBtn, langBtn, hideBtn)) {
            bar.addView(b, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, (28 * dp).toInt()).apply { marginEnd = (6 * dp).toInt() })
        }
        status.gravity = Gravity.END
        bar.addView(status, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).apply { marginStart = (8 * dp).toInt() })
        bar.addView(dot, LinearLayout.LayoutParams((8 * dp).toInt(), (8 * dp).toInt()).apply { marginStart = (8 * dp).toInt() })

        val surfaceHost = FrameLayout(this).apply {
            addView(keyboard, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
            addView(flight, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        }
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        column.addView(bar, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, (36 * dp).toInt()))
        column.addView(surfaceHost, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        pairing = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
            gravity = Gravity.CENTER
            setPadding((28 * dp).toInt(), (20 * dp).toInt(), (28 * dp).toInt(), (20 * dp).toInt())
            background = GradientDrawable().apply { cornerRadius = 18 * dp; setColor(Color.argb(235, 20, 22, 30)) }
            visibility = View.GONE
        }
        banner = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            setPadding((12 * dp).toInt(), (4 * dp).toInt(), (12 * dp).toInt(), (4 * dp).toInt())
            background = GradientDrawable().apply { cornerRadius = 12 * dp; setColor(Color.argb(200, 30, 32, 44)) }
            visibility = View.GONE
        }
        val root = FrameLayout(this)
        root.addView(column, FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
        root.addView(pairing, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.CENTER))
        root.addView(banner, FrameLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.TOP or Gravity.CENTER_HORIZONTAL).apply { topMargin = (6 * dp).toInt() })
        // The camera cutout + any visible system status bar: keep controls out from under them.
        root.setOnApplyWindowInsetsListener { _, insets ->
            val (l, r, topInset) = if (Build.VERSION.SDK_INT >= 30) {
                val c = insets.getInsets(WindowInsets.Type.displayCutout())
                val sb = insets.getInsets(WindowInsets.Type.statusBars())
                Triple(c.left, c.right, sb.top)
            } else {
                Triple(insets.displayCutout?.safeInsetLeft ?: 0, insets.displayCutout?.safeInsetRight ?: 0, 0)
            }
            column.setPadding(0, topInset, 0, 0)
            keyboard.setPadding(l, 0, r, 0)
            flight.setPadding(l, 0, r, 0)
            bar.setPadding(l + (8 * dp).toInt(), 0, r + (12 * dp).toInt(), 0)
            insets
        }
        setContentView(root)
        hideSystemBars()
        root.post { hideSystemBars() }

        if (Build.VERSION.SDK_INT >= 33) {
            // Back gestures while typing are accidents: never leave the keyboard because of one.
            onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT) { }
        }

        ConnectionManager.onChange.add(onConn)
        ConnectionManager.onLegends.add(onLegends)
        ConnectionManager.onLinkReady.add(onLinkReady)
        InputController.onState.add(onInput)
        InputController.onStallRecovered.add(onStall)
        InputController.startWatchdog()
        applySettings()
        if (!Settings.onboarded) {
            Settings.onboarded = true
            keyboard.post { showWelcome() }
        }
    }

    override fun onDestroy() {
        ConnectionManager.onChange.remove(onConn)
        ConnectionManager.onLegends.remove(onLegends)
        ConnectionManager.onLinkReady.remove(onLinkReady)
        InputController.onState.remove(onInput)
        InputController.onStallRecovered.remove(onStall)
        FlightController.stopLoop()
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        ConnectionManager.start()
        if (isMsfs()) FlightController.startLoop()
        updateStatus()
    }

    override fun onStop() {
        releaseAllInputs()
        FlightController.stopLoop()
        TypingAssist.save()
        ConnectionManager.stop()
        super.onStop()
    }

    override fun onResume() {
        super.onResume()
        hideSystemBars()
    }

    override fun onPause() {
        releaseAllInputs()
        super.onPause()
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Older Android: same as above, ignore accidental Back.
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideSystemBars() else releaseAllInputs()
    }

    private fun hideSystemBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_FULLSCREEN or
                View.SYSTEM_UI_FLAG_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION or View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN)
        }
    }

    private fun pill(text: String, onClick: () -> Unit) = TextView(this).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
        minWidth = (40 * dp).toInt()
        setPadding((12 * dp).toInt(), 0, (12 * dp).toInt(), 0)
        setOnClickListener { onClick() }
    }

    // MARK: state

    private fun switchPreset(id: String) {
        if (Settings.presetId == id) return
        releaseAllInputs()
        InputController.releaseAll()
        Settings.presetId = id
        applySettings()
    }

    private fun applySettings() {
        val t = KTheme.byId(Settings.themeId)
        val msfs = isMsfs()
        keyboard.theme = t
        flight.theme = t
        keyboard.visibility = if (msfs) View.GONE else View.VISIBLE
        flight.visibility = if (msfs) View.VISIBLE else View.GONE
        if (msfs) {
            FlightController.syncSettings()
            FlightController.startLoop()
        } else {
            FlightController.stopLoop()
        }

        window.decorView.setBackgroundColor(t.bg)
        bar.setBackgroundColor(t.bar)
        bar.visibility = if (Settings.showTopBar) View.VISIBLE else View.GONE
        textBtn.visibility = if (msfs) View.GONE else View.VISIBLE
        langBtn.visibility = if (msfs) View.GONE else View.VISIBLE
        status.setTextColor(t.textDim)
        for (b in listOf(langBtn, textBtn, menuBtn, hideBtn)) {
            b.setTextColor(t.text)
            b.background = GradientDrawable().apply { cornerRadius = 14 * dp; setColor(KTheme.alpha(t.key, 0.8f)) }
        }
        keyboard.relayout()
        keyboard.updateLegends()
        flight.relayout()
        flight.updatePcStatus()
        updateStatus()
    }

    private fun updateStatus() {
        val cm = ConnectionManager
        val t = KTheme.byId(Settings.themeId)
        val connected = cm.phase == ConnectionManager.Phase.CONNECTED
        val color = when (cm.phase) {
            ConnectionManager.Phase.CONNECTED -> Color.rgb(60, 200, 110)
            ConnectionManager.Phase.PAIRING, ConnectionManager.Phase.CONNECTING -> Color.rgb(240, 180, 60)
            else -> Color.rgb(230, 80, 80)
        }
        dot.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(color) }
        status.text = if (connected) {
            listOfNotNull(cm.pcName.ifEmpty { null }, cm.statusDetail, cm.rttMs?.let { "$it мс" }).joinToString(" · ")
        } else cm.statusDetail
        status.setTextColor(if (connected) t.textDim else t.text)
        langBtn.text = cm.pcState?.lang ?: "—"

        val code = cm.pairingCode
        if (code != null) {
            pairing.text = "Код подключения\n\n${code.chunked(3).joinToString(" ")}\n\nПодтвердите его в окне LocalKeys на ПК"
            pairing.visibility = View.VISIBLE
        } else {
            pairing.visibility = View.GONE
        }
        // Top bar hidden: still say when the PC is not connected, without blocking the keys.
        if (!Settings.showTopBar && !connected && code == null && cm.phase != ConnectionManager.Phase.IDLE) {
            banner.text = cm.statusDetail
            banner.visibility = View.VISIBLE
        } else {
            banner.visibility = View.GONE
        }
    }

    /** The cockpit/keys take the whole screen; menu remains via on-screen button or long Fn press. */
    private fun hideTopBar() {
        Settings.showTopBar = false
        applySettings()
        val msg = if (isMsfs()) "Панель скрыта. Меню — кнопка «Меню» на экране" else "Панель скрыта. Меню — удерживайте Fn 1 секунду"
        android.widget.Toast.makeText(this, msg, android.widget.Toast.LENGTH_LONG).show()
    }

    // MARK: language

    private fun showLangMenu() {
        val st = ConnectionManager.pcState
        val menu = PopupMenu(ContextThemeWrapper(this, android.R.style.Theme_Material), langBtn)
        if (st == null || st.layouts.isEmpty()) {
            menu.menu.add("Нет подключения к ПК").isEnabled = false
        } else {
            st.layouts.forEachIndexed { i, l ->
                menu.menu.add(0, i, i, l.name).apply { isCheckable = true; isChecked = l.id == st.layoutId }
            }
            menu.setOnMenuItemClickListener { item ->
                st.layouts.getOrNull(item.itemId)?.let { ConnectionManager.sendCommand("setLayout", it.id) }
                true
            }
        }
        menu.show()
    }

    // MARK: dialogs

    private fun dialogContext(): Context = ContextThemeWrapper(this, android.R.style.Theme_Material_Dialog_Alert)

    private fun widen(d: AlertDialog) {
        val w = resources.displayMetrics.widthPixels
        d.window?.setLayout((w * 0.82f).roundToInt().coerceAtMost((720 * dp).toInt()), ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    private fun showTextPanel() {
        val ctx = dialogContext()
        val edit = EditText(ctx).apply {
            hint = "Текст для ПК (можно любой язык, эмодзи)"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 2
            maxLines = 5
        }
        val box = FrameLayout(ctx).apply {
            setPadding((20 * dp).toInt(), (8 * dp).toInt(), (20 * dp).toInt(), 0)
            addView(edit)
        }
        val d = AlertDialog.Builder(ctx)
            .setTitle("Ввод текста")
            .setView(box)
            .setPositiveButton("Отправить") { _, _ -> InputController.text(edit.text.toString()) }
            .setNeutralButton("Отправить + Enter") { _, _ ->
                InputController.text(edit.text.toString())
                InputController.tapCombo(listOf(Keys.ENTER))
            }
            .setNegativeButton("Закрыть", null)
            .create()
        d.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE)
        d.show()
        widen(d)
        edit.requestFocus()
    }

    private fun showWelcome() {
        val ctx = dialogContext()
        val tv = TextView(ctx).apply {
            text = "Клавиатура Dark Project 68 и игровой пульт для вашего ПК.\n\n" +
                "• Wi-Fi: телефон и ПК в одной сети, на ПК запущен LocalKeys. При первом подключении подтвердите код на ПК.\n" +
                "• Кабель: включите «Отладку по USB» (подробно — в Меню → «Подключение по кабелю»).\n\n" +
                "Fn + цифры — F1…F12, Fn + стрелки — громкость и треки.\n" +
                "Подержите Fn одну секунду — откроется меню с выбором пресета (например, MSFS 2020) и настройками."
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(Color.rgb(215, 220, 232))
            setPadding((22 * dp).toInt(), (10 * dp).toInt(), (22 * dp).toInt(), (8 * dp).toInt())
        }
        val scroll = ScrollView(ctx).apply { addView(tv) }
        val d = AlertDialog.Builder(ctx)
            .setTitle("LocalKeys")
            .setView(scroll)
            .setPositiveButton("Понятно", null)
            .show()
        widen(d)
    }

    private fun showSettings() {
        val ctx = dialogContext()
        val col = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding((20 * dp).toInt(), (4 * dp).toInt(), (20 * dp).toInt(), (12 * dp).toInt())
        }
        val ui = SettingsUi(ctx, col, dp) { applySettings() }
        val cm = ConnectionManager

        // Preset selector right at the top (so holding Fn opens preset switching immediately).
        ui.section("Режим / Пресет")
        val presetRow = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            isBaselineAligned = false
        }
        val presetCards = ArrayList<Pair<Preset, LinearLayout>>()
        val msfsBox = LinearLayout(ctx).apply { orientation = LinearLayout.VERTICAL }

        fun refreshPresetUi() {
            val cur = Presets.byId(Settings.presetId).id
            val accent = KTheme.byId(Settings.themeId).accent
            for ((p, card) in presetCards) {
                val active = p.id == cur
                card.background = GradientDrawable().apply {
                    cornerRadius = 12 * dp
                    setColor(if (active) KTheme.blend(Color.rgb(52, 56, 70), accent, 0.24f) else Color.rgb(50, 53, 64))
                    setStroke(((if (active) 2f else 1f) * dp).roundToInt().coerceAtLeast(1), if (active) accent else Color.argb(40, 255, 255, 255))
                }
            }
            msfsBox.visibility = if (isMsfs()) View.VISIBLE else View.GONE
        }

        Presets.all.forEachIndexed { idx, p ->
            val card = LinearLayout(ctx).apply {
                orientation = LinearLayout.VERTICAL
                setPadding((14 * dp).toInt(), (12 * dp).toInt(), (14 * dp).toInt(), (12 * dp).toInt())
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    switchPreset(p.id)
                    refreshPresetUi()
                }
            }
            card.addView(TextView(ctx).apply {
                text = p.name
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
                typeface = Typeface.DEFAULT_BOLD
                setTextColor(Color.WHITE)
            })
            card.addView(TextView(ctx).apply {
                text = p.subtitle
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                setTextColor(Color.argb(190, 255, 255, 255))
                setPadding(0, (4 * dp).toInt(), 0, 0)
            })
            presetCards.add(p to card)
            val lp = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f).apply {
                if (idx > 0) marginStart = (10 * dp).toInt()
            }
            presetRow.addView(card, lp)
        }
        col.addView(presetRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            topMargin = (8 * dp).toInt()
        })

        // MSFS 2020 options shown cleanly right under the preset selector when active.
        val msfsUi = SettingsUi(ctx, msfsBox, dp) {
            FlightController.syncSettings()
            applySettings()
        }
        msfsUi.section("Настройки MSFS 2020")
        val joyModes = listOf("kb", "vjoy")
        msfsUi.choice(
            "Способ управления",
            listOf("Клавиатура MSFS (стандарт)", "vJoy (аналог)"),
            joyModes.indexOf(Settings.msfsInputMode).coerceAtLeast(0)
        ) {
            Settings.msfsInputMode = joyModes[it]
        }
        val joyStatusText = msfsUi.text("")
        fun refreshJoyStatus() {
            val st = cm.pcState?.joystick
            joyStatusText.text = when {
                Settings.msfsInputMode == "kb" ->
                    "Стандарт MSFS: работает на обычных настройках игры без переназначений. Важно: NumLock на ПК должен быть включён."
                st == "ok" -> "vJoy на ПК: подключён (8 осей, 32 кнопки)."
                st == "busy" -> "vJoy на ПК: занят другой программой."
                cm.phase == ConnectionManager.Phase.CONNECTED ->
                    "vJoy на ПК не найден — переключитесь на «Клавиатура MSFS (стандарт)» или установите vJoy."
                else -> "vJoy: нет подключения к ПК."
            }
        }
        refreshJoyStatus()
        msfsUi.slider("Отклик штурвала (клавиатура)", 700, 2200, Settings.msfsStickTravelMs, {
            when { it <= 950 -> "быстрый ($it мс)"; it >= 1650 -> "плавный ($it мс)"; else -> "средний ($it мс)" }
        }) { Settings.msfsStickTravelMs = it }
        msfsUi.slider("Скорость обзора камерой", 50, 250, (Settings.msfsCameraSens * 100).roundToInt(), { "$it%" }) {
            Settings.msfsCameraSens = it / 100f
        }
        msfsUi.slider("Угол наклона (гироскоп)", 12, 45, Settings.msfsTiltRangeDeg.roundToInt(), { "$it°" }) {
            Settings.msfsTiltRangeDeg = it.toFloat()
        }
        msfsUi.switch("Инверсия тангажа (вверх/вниз)", Settings.msfsInvertY) { Settings.msfsInvertY = it }
        col.addView(msfsBox, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        refreshPresetUi()

        ui.section("Подключение")
        val connText = ui.text("")
        fun refreshConn() {
            val pcs = if (cm.discovered.isEmpty()) "не найдены" else cm.discovered.joinToString(", ") { it.name }
            connText.text = "Состояние: ${cm.statusDetail.ifEmpty { "—" }}" +
                (if (cm.pcName.isNotEmpty()) "\nПК: ${cm.pcName}" else "") +
                "\nПК в сети: $pcs" + (if (cm.scanning) " (поиск…)" else "") +
                "\nКабель: " + (if (cm.usbLinked) "подключён" else "нет")
            refreshJoyStatus()
        }
        refreshConn()
        val connListener: () -> Unit = { refreshConn() }
        cm.onChange.add(connListener)

        ui.switch("Wi-Fi", Settings.wifiEnabled) { Settings.wifiEnabled = it; cm.reconnectWifi() }
        ui.switch("USB-кабель (через отладку по USB)", Settings.usbEnabled) { Settings.usbEnabled = it; cm.reconnectUsb() }
        ui.edit("Адрес ПК вручную (необязательно)", Settings.manualHost, "например 192.168.1.20") {
            Settings.manualHost = it.trim(); cm.reconnectWifi()
        }
        ui.button("Найти ПК в сети") { cm.scanNetwork() }
        if (cm.discovered.size > 1) {
            val names = listOf("Любой") + cm.discovered.map { it.name }
            ui.choice("Подключаться к", names, names.indexOf(Settings.preferredPC).coerceAtLeast(0)) {
                Settings.preferredPC = if (it == 0) "" else names[it]; cm.reconnectWifi()
            }
        }
        ui.edit("Имя этого телефона на ПК", Settings.deviceName, "") { if (it.isNotBlank()) Settings.deviceName = it.trim() }
        ui.button("Отпустить все клавиши на ПК") { InputController.releaseAll(); releaseAllInputs() }

        ui.section("Подключение по кабелю")
        ui.text(
            "1. Настройки → «О телефоне» → 7 раз нажмите на «Версия ОС» — включится режим разработчика.\n" +
                "2. Настройки → «Дополнительные настройки» → «Для разработчиков» → включите «Отладка по USB».\n" +
                "3. Подключите телефон кабелем к ПК и разрешите отладку (отметьте «Всегда разрешать с этого компьютера»).\n" +
                "4. На ПК нужен LocalKeys 1.6 или новее: кабель подхватится сам, сверху будет «USB-кабель». " +
                "Wi-Fi при этом остаётся в резерве и подхватит ввод, если выдернуть кабель."
        )

        ui.section("Клавиатура")
        ui.choice("Тема", KTheme.all.map { it.name }, KTheme.all.indexOfFirst { it.id == Settings.themeId }.coerceAtLeast(0)) {
            Settings.themeId = KTheme.all[it].id
        }
        ui.switch("Вибрация при нажатии", Settings.haptics) { Settings.haptics = it }
        ui.switch("Звук нажатия", Settings.keySound) { Settings.keySound = it }
        ui.switch("Залипание модификаторов (тап — один раз, двойной тап — закрепить)", Settings.stickyModifiers) { Settings.stickyModifiers = it }
        ui.switch("Верхняя панель (меню — кнопка на экране или долгий Fn)", Settings.showTopBar) { Settings.showTopBar = it }
        ui.slider("Размер клавиатуры", 60, 100, (Settings.kbScale * 100).roundToInt(), { "$it%" }) { Settings.kbScale = it / 100f }
        ui.slider("Высота клавиш", 100, 180, (Settings.keyAspect * 100).roundToInt(), { "${it}% ширины" }) { Settings.keyAspect = it / 100f }
        ui.slider("Положение (если клавиатура меньше экрана)", 0, 100, (Settings.vpos * 100).roundToInt(), {
            when { it < 20 -> "вверху"; it > 80 -> "внизу"; else -> "по центру" }
        }) { Settings.vpos = it / 100f }
        ui.slider("Промежуток между клавишами", 0, 12, Settings.keyGap.roundToInt(), { "$it dp" }) { Settings.keyGap = it.toFloat() }

        ui.section("Точность нажатий")
        ui.text(
            "Клавиатура учится, куда именно вы попадаете по каждой клавише (большие пальцы обычно " +
                "промахиваются одинаково), и незаметно сдвигает её зону. Стёрли букву и нажали соседнюю — " +
                "она запомнит, что это был промах.\n" +
                "Слова: при нажатии на стык двух букв выигрывает та, что продолжает слово (RU, UA, EN). " +
                "Граница сдвигается не больше чем на 1/5 клавиши; с Ctrl, Alt, Win, Fn и в играх " +
                "(зажатые клавиши) — не участвуют."
        )
        ui.switch("Подстраиваться под мои нажатия", Settings.smartTouch) { Settings.smartTouch = it }
        ui.switch("Учитывать слова", Settings.smartWords) { Settings.smartWords = it }
        ui.switch("Показывать точки, куда я попадаю", Settings.showTouchDots) { Settings.showTouchDots = it }
        ui.button("Сбросить обучение") { TypingAssist.forget() }

        ui.section("Подписи клавиш")
        val modes = listOf("auto", "en", "ru", "ua")
        ui.choice("Язык подписей", listOf("Как на ПК", "EN", "RU", "UA"), modes.indexOf(Settings.legendMode).coerceAtLeast(0)) {
            Settings.legendMode = modes[it]
        }
        ui.switch("Двуязычные подписи", Settings.bilingual) { Settings.bilingual = it }
        val langs = listOf("ru", "ua", "none")
        ui.choice("Второй язык при английской раскладке", listOf("Русский", "Українська", "Нет"), langs.indexOf(Settings.secondLang).coerceAtLeast(0)) {
            Settings.secondLang = langs[it]
        }
        ui.slider("Размер второго языка", 40, 100, (Settings.altScale * 100).roundToInt(), { "$it% от основной" }) {
            Settings.altScale = it / 100f
        }
        ui.switch("Символы второго языка с Shift (« \" » и « № » на 2 и 3…)", Settings.altShifted) { Settings.altShifted = it }

        ui.section("Прочее")
        ui.button("Забыть все сопряжения с ПК") {
            Settings.forgetAllPairings(); cm.reconnectWifi(); cm.reconnectUsb()
        }
        val ver = try { packageManager.getPackageInfo(packageName, 0).versionName } catch (_: Exception) { "?" }
        ui.text("LocalKeys для Android $ver · пресеты Dark Project 68 и MSFS 2020\n" +
            "Словари: FrequencyWords (Hermit Dave, OpenSubtitles), CC BY-SA 4.0")

        // A plain Dialog: AlertDialog clips a long custom view instead of letting it scroll.
        val d = android.app.Dialog(ctx)
        d.requestWindowFeature(android.view.Window.FEATURE_NO_TITLE)
        val frame = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply { cornerRadius = 16 * dp; setColor(Color.rgb(40, 42, 50)) }
        }
        val header = LinearLayout(ctx).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding((20 * dp).toInt(), (10 * dp).toInt(), (8 * dp).toInt(), (4 * dp).toInt())
        }
        header.addView(TextView(ctx).apply {
            text = "Меню"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
            typeface = Typeface.DEFAULT_BOLD
        }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(Button(ctx).apply {
            text = "Готово"
            isAllCaps = false
            setOnClickListener { d.dismiss() }
        })
        frame.addView(header)
        frame.addView(ScrollView(ctx).apply { addView(col) }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        d.setContentView(frame)
        d.window?.setBackgroundDrawable(android.graphics.drawable.ColorDrawable(Color.TRANSPARENT))
        d.setOnDismissListener { ui.flush(); cm.onChange.remove(connListener); hideSystemBars() }
        d.show()
        val w = resources.displayMetrics.widthPixels
        d.window?.setLayout((w * 0.82f).roundToInt().coerceAtMost((760 * dp).toInt()), (resources.displayMetrics.heightPixels * 0.94f).roundToInt())
    }
}

/** Small builder for the settings dialog rows (no AndroidX / preference library needed). */
private class SettingsUi(val ctx: Context, val col: LinearLayout, val dp: Float, val changed: () -> Unit) {
    private fun lp(top: Int = 6) = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        .apply { topMargin = (top * dp).toInt() }

    fun section(title: String) {
        col.addView(TextView(ctx).apply {
            text = title
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = Typeface.DEFAULT_BOLD
            setTextColor(Color.rgb(120, 150, 255))
        }, lp(18))
    }

    fun text(s: String): TextView {
        val t = TextView(ctx).apply {
            text = s
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            alpha = 0.85f
        }
        col.addView(t, lp())
        return t
    }

    fun switch(title: String, value: Boolean, set: (Boolean) -> Unit) {
        @Suppress("DEPRECATION")
        val s = Switch(ctx).apply {
            text = title
            isChecked = value
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setOnCheckedChangeListener { _: CompoundButton, v: Boolean -> set(v); changed() }
        }
        col.addView(s, lp(8))
    }

    fun slider(title: String, min: Int, max: Int, value: Int, fmt: (Int) -> String, set: (Int) -> Unit) {
        val label = TextView(ctx).apply { setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f) }
        fun show(v: Int) { label.text = "$title: ${fmt(v)}" }
        show(value)
        val bar = SeekBar(ctx).apply {
            this.max = max - min
            progress = (value - min).coerceIn(0, max - min)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, p: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    show(p + min); set(p + min); changed()
                }
                override fun onStartTrackingTouch(sb: SeekBar) {}
                override fun onStopTrackingTouch(sb: SeekBar) {}
            })
        }
        col.addView(label, lp(10))
        col.addView(bar, lp(2))
    }

    fun choice(title: String, options: List<String>, selected: Int, set: (Int) -> Unit) {
        col.addView(TextView(ctx).apply { text = title; setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f) }, lp(10))
        val g = RadioGroup(ctx).apply { orientation = RadioGroup.HORIZONTAL }
        options.forEachIndexed { i, o ->
            g.addView(RadioButton(ctx).apply {
                id = View.generateViewId()
                text = o
                isChecked = i == selected
                setOnCheckedChangeListener { _, on -> if (on) { set(i); changed() } }
            })
        }
        val sc = android.widget.HorizontalScrollView(ctx).apply { addView(g) }
        col.addView(sc, lp(2))
    }

    private val pending = ArrayList<() -> Unit>()

    /** Text fields apply when they lose focus, on Enter, or when the dialog closes. */
    fun edit(title: String, value: String, hint: String, set: (String) -> Unit) {
        col.addView(TextView(ctx).apply { text = title; setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f) }, lp(10))
        var applied = value
        val e = EditText(ctx)
        val apply = { val v = e.text.toString(); if (v != applied) { applied = v; set(v); changed() } }
        e.apply {
            setText(value)
            this.hint = hint
            isSingleLine = true
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
            setOnFocusChangeListener { _, has -> if (!has) apply() }
            setOnEditorActionListener { v, _, _ -> apply(); v.clearFocus(); false }
        }
        pending.add(apply)
        col.addView(e, lp(2))
    }

    fun flush() = pending.forEach { it() }

    fun button(title: String, action: () -> Unit) {
        col.addView(Button(ctx).apply {
            text = title
            isAllCaps = false
            setOnClickListener { action(); changed() }
        }, lp(8))
    }
}
