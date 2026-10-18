case "${1:-}" in
  --help|-h|help)
    usage
    ;;
  status)
    show_status
    ;;
  update)
    update_ola_command
    ;;
  doctor)
    show_doctor
    ;;
  test)
    run_ola_test
    ;;
  bench)
    if [[ "${2:-}" == "--stream" ]]; then
      run_stream_bench "${3:-}"
    else
      run_bench "${2:-}"
    fi
    ;;
  fluid)
    case "${2:-status}" in
      status)
        show_fluid_status
        ;;
      warm)
        warm_model_command "${3:-}"
        ;;
      preset)
        fluid_preset "${3:-}"
        ;;
      bench)
        run_stream_bench "${3:-}"
        ;;
      keepalive)
        if [[ -z "${3:-}" ]]; then
          err "Usage: ola fluid keepalive <durée|reset> (exemples : 30m, 1h, 2h30m, 3600, -1 ; reset = retour à 5m)"
          exit 1
        fi
        if [[ "$3" == "reset" ]]; then
          keepalive_target="5m"
        elif is_valid_keep_alive "$3"; then
          keepalive_target="$3"
        else
          err "Invalid keep-alive duration: $3 (expected something like 30m, 1h, 2h30m, 3600 seconds, or -1; reset restores 5m)"
          exit 1
        fi
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        apply_keep_alive "$keepalive_target"
        ;;
      *)
        err "Usage: ola fluid [status|warm [model]|preset [model]|bench [model]|keepalive <duration|reset>]"
        exit 1
        ;;
    esac
    ;;
  tui)
    case "${2:-launch}" in
      launch)
        launch_ola_tui
        ;;
      install)
        repair_tui_environment
        ;;
      status)
        show_tui_status
        ;;
      *)
        err "Usage: ola tui [install|status] (no argument launches the interface)"
        exit 1
        ;;
    esac
    ;;
  speed)
    case "${2:-status}" in
      status)
        show_speed
        ;;
      apply)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        apply_speed_mode speed
        ;;
      reset|off)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        apply_speed_mode balanced
        ;;
      *)
        err "Usage: ola speed [status|apply|reset]"
        exit 1
        ;;
    esac
    ;;
  use)
    require_root
    if [[ -z "${2:-}" ]]; then
      err "Usage: ola use <model> (example: ola use qwen3:1.7b)"
      exit 1
    fi
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    switch_model "$2"
    ;;
  models)
    if [[ -t 0 && -t 1 ]]; then
      model_manager
    else
      show_installed_models
    fi
    ;;
  ps)
    show_loaded_models
    ;;
  delete|rm)
    require_root
    if [[ -z "${2:-}" ]]; then
      err "Usage: ola delete <model> [--force] (example: ola delete qwen3:1.7b)"
      exit 1
    fi
    delete_force=0
    if [[ "${3:-}" == "--force" ]]; then
      delete_force=1
    elif [[ -n "${3:-}" ]]; then
      err "Unknown delete option: $3 (only --force is supported)"
      exit 1
    fi
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    delete_model_command "$2" "$delete_force"
    ;;
  unload)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    unload_models_command "${2:-}"
    ;;
  watchdog)
    show_watchdog
    ;;
  watchdog-daemon)
    require_root
    run_watchdog_daemon
    ;;
  recover)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    recover_services
    ;;
  logs)
    show_logs
    ;;
  setup)
    require_root
    check_system
    setup_all
    ;;
  start|restart)
    require_root
    install_ola_command
    require_supervisor_running
    ensure_watchdog
    restart_services
    ;;
  stop)
    require_root
    install_ola_command
    require_supervisor_running
    stop_tunnel
    ;;
  "")
    echo "===================================="
    echo " Ollama + Cloudflare Tunnel Manager"
    echo "===================================="
    echo "1) Full setup (Ollama + model + tunnel)"
    echo "2) Status"
    echo "3) Doctor (full diagnostic)"
    echo "4) Test API + model"
    echo "5) Show logs"
    echo "6) Start/restart Ollama and tunnel"
    echo "7) Recover stopped/unhealthy services"
    echo "8) Use another model (unload current from RAM first)"
    echo "9) Unload loaded model(s) from RAM"
    echo "10) Delete a model from disk"
    echo "11) Watchdog status"
    echo "12) Benchmark vitesse (ola bench)"
    echo "13) Vitesse / Pack Speed (état)"
    echo "14) Fluidité (état, ola fluid)"
    echo "15) Stop tunnel"
    echo "16) Update ola (download + verified install + restart)"
    echo "17) Exit"
    if ! choice=$(prompt_value "Choice [17]: " "17"); then
      warn "No input received; exiting."
      exit 0
    fi
    case "$choice" in
      1) require_root; check_system; setup_all ;;
      2) show_status ;;
      3) show_doctor ;;
      4) run_ola_test ;;
      5) show_logs ;;
      6) require_root; install_ola_command; require_supervisor_running; ensure_watchdog; restart_services ;;
      7) require_root; install_ola_command; require_supervisor_running; ensure_watchdog; recover_services ;;
      8)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        if ! model_choice=$(prompt_value "Model to use (example qwen3:1.7b): " ""); then
          die "No model received; cancelling model switch."
        fi
        switch_model "$model_choice"
        ;;
      9)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        if ! model_choice=$(prompt_value "Model to unload (blank = all loaded): " ""); then
          die "No input received; cancelling unload."
        fi
        unload_models_command "$model_choice"
        ;;
      10)
        require_root
        install_ola_command
        require_supervisor_running
        ensure_watchdog
        show_installed_models || true
        if ! model_choice=$(prompt_value "Model to permanently delete from disk: " ""); then
          die "No model received; cancelling deletion."
        fi
        delete_force=0
        current_default=$(saved_model_name)
        if [[ "$(normalize_model_name "$current_default")" == "$(normalize_model_name "$model_choice")" ]]; then
          delete_force=1
        fi
        delete_model_command "$model_choice" "$delete_force"
        ;;
      11) show_watchdog ;;
      12) run_bench "" ;;
      13) show_speed ;;
      14) show_fluid_status ;;
      15) require_root; install_ola_command; require_supervisor_running; stop_tunnel ;;
      16) update_ola_command ;;
      17) exit 0 ;;
      *) die "Invalid choice." ;;
    esac
    ;;
  *)
    err "Unknown argument: $1 (use --help)."
    usage >&2
    exit 1
    ;;
esac
