
# Server ------------------------------------------------------------------
server <- function(input, output, session) {
  # ---- Global - Debug ----
  observeEvent(input$debug_browse, {
    browser()
  })
  
  # ---- Global - Session Temp Directory ----
  SESSION_TEMPDIR <- file.path("www", session$token)
  dir.create(SESSION_TEMPDIR, showWarnings = FALSE)
  onStop(function() {
    message("Removing session tempdir: ", SESSION_TEMPDIR)
    unlink(SESSION_TEMPDIR, recursive = TRUE)
  })
  message("Using session tempdir: ", SESSION_TEMPDIR)
  
  # ---- Global - Bookmarking ----
  onBookmark(function(state) {
    state$values$rvn <- list()
    state$values$rvn$nodes <- rvn$nodes
    state$values$rve <- list()
    state$values$rve$edges <- rve$edges
    state$values$query_string <- session$clientData$url_search
    
    # Store outcome/exposure/adjust node selections
    state$values$sel <- list(
      exposureNode = input$exposureNode,
      outcomeNode = input$outcomeNode,
      adjustNode = input$adjustNode
    )
  })
  
  onBookmarked(function(url) {
    message("bookmark: ", url)
    showBookmarkUrlModal(url)
    updateQueryString(url)
  })
  
  onRestore(function(state) {
    showModal(modalDialog(
      title = NULL,
      easyClose = FALSE,
      footer = NULL,
      tags$p(class = "text-center", "Loading your shinyDag workspace, please wait."),
      tags$div(class = "gerkelab-spinner")
    ))
    
    # clear selected node and text input to try to prevent existing values from
    # changing the name of the node that gets selected on restore
    rvn$nodes <- node_unset_attribute(rvn$nodes, names(rvn$nodes), "parent")
    updateTextInput(session, "node_list_node_name", value = "")
    
    if (isTRUE(getOption("shinydag.debug", FALSE))) {
      names(state$values) %>%
        purrr::set_names() %>%
        purrr::map(~ state$values[[.]]) %>%
        purrr::compact() %>%
        purrr::iwalk(~ debug_input(.x, paste0("state$values$", .y)))
    }
    rvn$nodes <- state$values$rvn$nodes
    rve$edges <- state$values$rve$edges
  })
  
  onRestored(function(state) {
    removeModal()
    updateSelectInput(session, "exposureNode", selected = state$values$sel$exposureNode)
    updateSelectInput(session, "outcomeNode", selected = state$values$sel$outcomeNode)
    updateSelectizeInput(session, "adjustNode", selected = state$values$sel$adjustNode)
  })
  
  # ---- Global - Reactive Values ----
  rve <- reactiveValues(edges = list())
  rvn <- reactiveValues(nodes = list())

  # rve$edges is a named list, e.g. for hash(A) -> hash(B):
  # rve$edges[edge_key(hash(A), hash(B))] = list(from = hash(A), to = hash(B))
  
  # rvn$nodes is a named list where name is a hash
  # rvn$nodes$abcdefg = list(name, x, y)
  
  # ---- Sketch - Reactive Values Undo/Redo ----
  rv_undo_state <- shinyThings::undoHistory(
    id = "undo_rv", 
    value = reactive({
      req(length(rvn$nodes) > 0)
      
      node_params <- c("name", "x", "y", "parent", "exposure", "outcome", "adjusted")
      nodes <- rvn$nodes %>% 
        purrr::map(`[`, node_params) %>% 
        purrr::map(purrr::compact)
      
      edge_params <- c("from", "to")
      edges <- rve$edges %>% 
        purrr::map(`[`, edge_params) %>% 
        purrr::map(purrr::compact)
      
      list(
        nodes = nodes,
        edges = edges
      )
    })
  )
  
  observe({
    req(!is.null(rv_undo_state()))
    
    rv_state <- rv_undo_state()
    debug_input(rv_state$nodes, "undo/redo - new nodes")
    debug_input(rv_state$edges, "undo/redo - new edges")
    rvn$nodes <- rv_state$nodes
    rve$edges <- rv_state$edges
  }, priority = 1000)

  # ---- Sketch - Node Controls ----
  node_btn_id <- function(node_hash) paste0("node_toggle_", node_hash)
  node_btn_get_hash <- function(node_btn_id) sub("node_toggle_", "", node_btn_id, fixed = TRUE)
  
  node_list_buttons_redraw <- reactiveVal(Sys.time())
  node_list_node_is_new <- reactiveVal(FALSE)
  node_list_selected_child <- reactive({ node_child(rvn$nodes) }) # TODO: remove
  node_list_selected_node <- reactiveVal(NULL)
  observe({
    I("update selected node?")
    # this feels hacky but on the one hand we want to be able to update the 
    # selected parent node just by updating rvn$nodes, and on the other we don't
    # want to propagate a reactive change if the value stays the same. So this
    # observer is kind of like a debouncer for node_list_selected_node()
    current_selected_node <- isolate(node_list_selected_node())
    new_selected_node <- node_parent(rvn$nodes)
    if (!identical(current_selected_node, new_selected_node)) {
      node_list_selected_node(new_selected_node)
    }
  })
  
  # debug selected nodes
  observe({
    debug_input(node_list_selected_node(), "node_list_selected_node")
    debug_input(node_list_selected_child(), "node_list_selected_child")
  })
  
  # Handle add node button, creates new node and sets focus
  observeEvent(input$node_list_node_add, {
    new_node_hash <- digest::digest(Sys.time())
    rvn$nodes <- node_new(rvn$nodes, new_node_hash, "new node") %>% 
      node_set_attribute(new_node_hash, "parent")
    node_list_buttons_redraw(Sys.time())
    node_list_node_is_new(TRUE)
  })
  
  # Show, hide or update node name text input
  observe({
    I("show/hide/update node name text box")
    if (is.null(node_list_selected_node())) {
      shinyjs::hide("node_list_node_name_container")
      return()
    } 
    
    s_node_selected <- node_list_selected_node()
    
    # Selected node already exists, update UI
    shinyjs::show("node_list_node_name_container")
    shinyjs::runjs("set_input_focus('node_list_node_name')")
    s_node_name <- node_name_from_hash(isolate(rvn$nodes), s_node_selected)
    if (isolate(node_list_node_is_new())) {
      node_list_node_is_new(FALSE)
      updateTextInput(session, "node_list_node_name", value = "", placeholder = "Enter Node Name")
    } else {
      updateTextInput(
        session, 
        "node_list_node_name", 
        value = unname(s_node_name)
      )
    }
  }, priority = 1000)
  
  # Handle node name text input
  node_name_text_input <- reactive({
    input$node_list_node_name
  })
  
  observe({
    I("update node name")
    node_name_debounced <- debounce(node_name_text_input, 750)
    node_name <- node_name_debounced()
    debug_input(node_name, "node_list_node_name (debounced)")
    s_node <- isolate(node_list_selected_node())
    req(s_node, node_name != "")
    rvn$nodes <- node_update(isolate(rvn$nodes), s_node, node_name)
  }, priority = 2000)
  
  # Show editing buttons when appropriate
  observe({
    I("toggle edit buttons")
    if (is.null(node_list_selected_node()) || !length(rvn$nodes)) {
      # no node selected, can only add a new node
      shinyjs::hide("node_list_node_delete")
    } else {
      # can now delete any selected node
      shinyjs::show("node_list_node_delete")
    }
  })
  
  # Action: delete node
  observeEvent(input$node_list_node_delete, {
    # Remove node
    node_to_delete <- node_list_selected_node()
    rvn$nodes[[node_to_delete]] <- NULL
    
    # Remove any edges
    edges_with_node <- rve$edges %>% 
      purrr::keep(~ node_to_delete %in% c(.$from, .$to)) %>% 
      names()
    
    if (length(edges_with_node)) rve$edges[edges_with_node] <- NULL
    
    updateRadioSwitchButtons("clickpad_click_action", selected = "parent")
    shinyjs::hide("node_list_node_name_container")
    shinyjs::hide("node_list_node_delete")
  })
  
  # ---- Sketch - Help Text ----
  output$node_list_helptext <- renderUI({
    s_node <- node_list_selected_node()
    no_nodes <- length(rvn$nodes) == 0
    not_enough_nodes <- length(rvn$nodes) < 2
    no_node_selected <- !no_nodes && is.null(s_node)
    no_dag_nodes <- !no_nodes && length(nodes_in_dag(rvn$nodes)) == 0
    not_enough_dag_nodes <- !no_dag_nodes && length(nodes_in_dag(rvn$nodes)) < 2
    node_in_dag <- !no_dag_nodes && s_node %in% nodes_in_dag(rvn$nodes)
    
    if (no_nodes) {
      helpText(
        "Use the", icon("plus"), "button above to add a node",
        "to your shinyDAG workspace"
      )
    } else if (not_enough_nodes) {
      helpText("Add another node to your shinyDAG workspace")
    } else if (no_dag_nodes) {
      helpText("Drag a node from the staging area into the DAG or click its label to edit")
    } else if (not_enough_dag_nodes) {
      helpText("Drag another node from the staging area into the DAG")
    } else if (input$clickpad_click_action == "parent") {
      helpText("Click on a node label to activate as causal node or to edit its label")
    } else if (input$clickpad_click_action == "child") {
      helpText(
        "Click on a node label to draw or remove a causal arrow from", 
        tags$strong(node_name_from_hash(rvn$nodes, node_list_selected_node())),
        "or click",
        tags$strong(node_name_from_hash(rvn$nodes, node_list_selected_node())),
        "again to deselect"
      )
    }
  })
  
  # ---- Sketch - Edge Help Text ----
  req_nodes <- function() {
    if (!length(rvn$nodes)) {
      cat("\n No Nodes!")
      edge_helptext("Please add a node to the DAG first.")
      FALSE
    } else TRUE
  }
  
  edge_helptext <- function(inner, tag = "div", class = "help-block text-danger alert-edge") {
    edge_helptext_trigger(Sys.time())
    edge_helptext_feedback(list(class = class, inner = inner, tag = tag))
  }
  
  edge_normal_help_html <- list(
    inner = "Double-click on a node to set parent node. Single-click to set child node.",
    class = "help-block",
    tag = "p"
  )
  edge_helptext_trigger <- reactiveVal(Sys.time())
  edge_helptext_feedback <- reactiveVal(NULL)
  
  output$edge_list_helptext <- renderUI({
    debug_input(isolate(edge_helptext_feedback()), "edge_helptext_feedback")
    
    edge_helptext_trigger()
    
    if (!is.null(isolate(edge_helptext_feedback()))) {
      invalidateLater(4800)
    } 
    
    html <- isolate(edge_helptext_feedback()) %||% edge_normal_help_html
    edge_helptext_feedback(NULL)
    tag(html$tag, list(class = html$class, html$inner))
  })
  
  # ---- Sketch - Clickpad ----
  plotly_source_id <- paste0("clickpad_", session$token)
  clickpad_new_locations <- callModule(
    clickpad, "clickpad", 
    nodes = reactive(rvn$nodes),
    edges = reactive(rve$edges),
    plotly_source = plotly_source_id
  )
  
  observe({
    new <- clickpad_new_locations()
    
    req(new)
    debug_input(new, "clickpad_new_locations()")
    
    rvn$nodes <- node_update(isolate(rvn$nodes), new$hash, x = unname(new$x), y = unname(new$y))
  })
  
  # ---- Sketch - Clickpad - Click Events ----
  observe({
    I("clickpad click event handler")
    clicked_annotation <- event_data(
      "plotly_clickannotation", source = plotly_source_id, priority = "event"
    )
    req(clicked_annotation[["_input"]]$node_hash)
    
    click_action = isolate(input$clickpad_click_action)
    clicked_hash = clicked_annotation[["_input"]]$node_hash
    
    nodes <- isolate(rvn$nodes)
    
    s_node_parent <- node_parent(nodes)
    s_node_child <- node_child(nodes)
    
    if (click_action == "parent") {
      # toggle clicked node as parent node
      update_button <- nodes[[clicked_hash]]$x >= 0 &&
        nodes %>% purrr::map_dbl("x") %>% { sum(. >= 0) > 1 }
      
      if (is.null(s_node_parent)) {
        nodes <- node_set_attribute(nodes, clicked_hash, "parent")
      } else if (clicked_hash == s_node_parent) {
        update_button <- FALSE
        nodes <- node_unset_attribute(nodes, clicked_hash, c("parent", "child"))
      } else {
        nodes <- node_set_attribute(nodes, clicked_hash, "parent")
        nodes <- node_unset_attribute(nodes, clicked_hash, "child")
      }
      if (update_button) updateRadioSwitchButtons("clickpad_click_action", "child")
      
    } else if (click_action == "child") {
      # toggle clicked node as child node
      has_edge <- edge_exists(isolate(rve$edges), s_node_parent, s_node_child %||% clicked_hash)
      has_reverse_edge <- edge_exists(isolate(rve$edges), s_node_child %||% clicked_hash, s_node_parent)
      
      if (!is.null(s_node_parent) && s_node_parent == clicked_hash) {
        # Can't add edges to self
        rvn$nodes <- node_unset_attribute(nodes, names(nodes), c("parent", "child"))
        updateRadioSwitchButtons("clickpad_click_action", "parent")
        return()
      } else if (has_edge) {
        # Clicked on child node that already has edge, will be removing edge
        nodes <- node_unset_attribute(nodes, clicked_hash, "child")
      } else if (nodes[[clicked_hash]]$x < 0) {
        showNotification(
          "Edges can only be drawn between nodes that are in the DAG area.",
          duration = 5,
          type = "error"
        )
        return()
      } else {
        nodes <- node_set_attribute(nodes, clicked_hash, "child")
      }
      
      # Remove reverse edge if it exists
      rv_edges <- isolate(rve$edges)
      if (has_reverse_edge) {
        rv_edges <- edge_toggle(rv_edges, clicked_hash, s_node_parent)
      }
      rve$edges <- edge_toggle(rv_edges, s_node_parent, clicked_hash)
    }
    rvn$nodes <- nodes
  })
  
  # ---- Sketch - Clickpad - Click Type Buttons ----
  observe({
    I("clickpad click action reset to select?")
    reset_clickpad_action <- function() {
      updateRadioSwitchButtons("clickpad_click_action", "parent")
      invisible()
    }
    
    if (length(rvn$nodes) < 2) return(reset_clickpad_action())
    
    dag_has_two_nodes <- rvn$nodes %>% purrr::map_dbl("x") %>% { sum(. >= 0) > 1 }
    if (!dag_has_two_nodes) return(reset_clickpad_action())
    
    if (!is.null(node_list_selected_node())) {
      if (rvn$nodes[[node_list_selected_node()]]$x < 0) {
        reset_clickpad_action()
      }
    }
  })
  
  # Don't allow clickpad edge adding unless node conditions are met
  observeEvent(input$clickpad_click_action, {
    req(input$clickpad_click_action == "child")
    valid <- FALSE
    if (length(rvn$nodes) < 2) {
      showNotification("Please add at least 2 nodes to your DAG workspace first.", duration = 5)
    } else if (rvn$nodes %>% purrr::keep(~ .$x >= 0) %>% length() < 2) {
      showNotification("Please drag at least 2 nodes into the DAG area first.", duration = 5)
    } else if (is.null(node_list_selected_node())) {
      showNotification("A parent node must be selected first", duration = 5)
    } else if (!length(nodes_in_dag(rvn$nodes))) {
      showNotification(
        "Please add a node to the DAG by dragging it out of the staging area.", 
        duration = 5
      )
    } else {
      valid <- TRUE
    }
    if (!valid) updateRadioSwitchButtons("clickpad_click_action", "parent")
  })
  
  # ---- Sketch - Node Options ----
  update_node_options <- function(
    nodes,
    inputId,
    updateFn,
    none_choice = TRUE,
    ...
  ) {
    available_choices <- c("None" = "", node_names(nodes))
    if (!none_choice) available_choices <- available_choices[-1]
    s_choice <- intersect(isolate(input[[inputId]]), available_choices)
    # If inputId doesn't overlap with choices, lookup state in rvn$nodes
    if (!length(s_choice) || s_choice == "") {
      s_choice <- switch(
        inputId,
        "adjustNode" = node_adjusted(nodes),
        "exposureNode" = node_exposure(nodes),
        "outcomeNode" = node_outcome(nodes),
        character(0)
      )
    }
    s_choice <- intersect(s_choice, available_choices)
    if (inputId == "adjustNode") debug_input(nodes, "nodes for E/O/A")
    debug_input(s_choice, inputId)
    # Fall back to the none choice
    if (!length(s_choice) && none_choice) {
      s_choice <- ""
    }
    
    updateFn(
      session,
      inputId,
      choices = available_choices,
      selected = s_choice,
      ...
    )
  }
  
  observe({
    update_node_options(
      rvn$nodes %>% purrr::keep(~ .$x >= 0), 
      "adjustNode", 
      updateSelectizeInput
    )
    update_node_options(
      rvn$nodes %>% purrr::keep(~ .$x >= 0), 
      "exposureNode", 
      updateSelectInput
    )
    update_node_options(
      rvn$nodes %>% purrr::keep(~ .$x >= 0), 
      "outcomeNode", 
      updateSelectInput
    )
  })
  
  observeEvent(input$exposureNode, {
    nodes <- isolate(rvn$nodes)
    if (input$exposureNode == "") {
      rvn$nodes <- node_unset_attribute(nodes, names(nodes), "exposure")
    } else if (input$exposureNode == input$outcomeNode) {
      updateSelectInput(session, "outcomeNode", selected = "")
      rvn$nodes <- node_unset_attribute(nodes, names(nodes), "outcome")
    } else {
      rvn$nodes <- node_set_attribute(nodes, input$exposureNode, "exposure")
    }
  })
  
  observeEvent(input$outcomeNode, {
    nodes <- isolate(rvn$nodes)
    if (input$outcomeNode == "") {
      rvn$nodes <- node_unset_attribute(nodes, names(nodes), "outcome")
    } else if (input$outcomeNode == input$exposureNode) {
      updateSelectInput(session, "exposureNode", selected = "")
      rvn$nodes <- node_unset_attribute(nodes, names(nodes), "exposure")
    } else {
      rvn$nodes <- node_set_attribute(nodes, input$outcomeNode, "outcome")
    }
  })
  
  observe({
    nodes <- isolate(rvn$nodes)
    debug_input(input$adjustNode, "input$adjustNode")
    s_adjust <- input$adjustNode %||% ""
    rvn$nodes <- if (length(s_adjust) == 1 && s_adjust == "") {
      node_unset_attribute(nodes, names(nodes), "adjusted")
    } else {
      node_set_attribute(nodes, s_adjust, "adjusted")
    }
  })
  
  output$adjustText <- renderText({
    if (is.null(input$exposureNode) & is.null(input$outcomeNode)) {
      paste0("Minimal sufficient adjustment sets")
    } else {
      paste0(
        "Minimal sufficient adjustment set(s) to estimate the effect of ",
        input$exposureNode,
        " on ",
        input$outcomeNode
      )
    }
  })
  
  # ---- DAG - Functions ----
  make_dagitty <- function(nodes, edges, exposure = NULL, outcome = NULL, adjusted = NULL) {
    dagitty_edges <- edge_frame(edges, nodes) %>% 
      glue::glue_data('"{from_name}" -> "{to_name}"') %>% 
      paste(collapse = "; ")
    
    dagitty_code <- glue::glue("dag {{ {dagitty_edges} }}")
    debug_input(dagitty_code, "dagitty_code")
    
    gdag <- dagitty(dagitty_code)
    
    if (isTruthy(exposure)) exposures(gdag) <- node_name_from_hash(nodes, exposure)
    if (isTruthy(outcome))  outcomes(gdag) <- node_name_from_hash(nodes, outcome)
    if (isTruthy(adjusted)) adjustedNodes(gdag) <- node_name_from_hash(nodes, adjusted)
    
    gdag
  }
  
  dagitty_open_paths <- function(nodes, edges, exposure, outcome, adjusted) {
    node_names <- invertNames(node_names(nodes))
    gd <- make_dagitty(
      edges = edges, nodes = nodes,
      exposure = exposure, outcome = outcome, adjusted = adjusted
    )

    exp_outcome_paths <- paths(
      gd,
      Z = adjusted %??% unname(node_names[adjusted])
    )

    exp_outcome_paths$paths[as.logical(exp_outcome_paths$open)]
  }
  
  dagitty_open_paths_causal <- function(nodes, edges, exposure, outcome, adjusted) {
    node_names <- invertNames(node_names(nodes))
    gd <- make_dagitty(
      edges = edges, nodes = nodes,
      exposure = exposure, outcome = outcome, adjusted = adjusted
    )
    
    exp_outcome_paths <- paths(
      gd,
      Z = adjusted %??% unname(node_names[adjusted]),
      directed=TRUE
    )
    
    exp_outcome_paths$paths[as.logical(exp_outcome_paths$open)]
  }
  
  dagitty_sets <- function(nodes, edges, exposure, outcome, adjusted) {
    node_names <- invertNames(node_names(nodes))
    gd <- make_dagitty(
      edges = edges, nodes = nodes,
      exposure = exposure, outcome = outcome, adjusted = adjusted
    )
    
    minimal_sets <- adjustmentSets(
      gd,
      exposure = exposure %??% unname(node_names[exposure]),
      outcome = outcome %??% unname(node_names[outcome]),
    )
    
  }
  
  dagitty_format_paths <- function(paths) {
    tagList(
      lapply(trimws(paths), function(x) tags$p(tags$code(x)))
    )
  }
  
  # ---- Sketch - DAG - Open Exp/Outcome Paths ----
  dagitty_has_required_nodes <- reactive({
    req(
      length(nodes_in_dag(rvn$nodes)),
      length(edges_in_dag(rve$edges, rvn$nodes))
    )
    
    # need both exposure and outcome node
    requires_nodes <- c("Exposure" = input$exposureNode, "Outcome" = input$outcomeNode)
    missing_nodes <- names(requires_nodes[grepl("^$", requires_nodes)])
    validate(
      need(
        length(missing_nodes) == 0,
        glue::glue("Please choose {str_and(missing_nodes)} {str_plural(missing_nodes, 'node')}")
      )
    )
    
    TRUE
  })
  
  dagitty_open_exp_outcome_paths <- reactive({
    dagitty_has_required_nodes()
    
    purrr::safely(dagitty_open_paths)(
      nodes = rvn$nodes, edges = rve$edges, exposure = input$exposureNode, 
      outcome = input$outcomeNode, adjusted = input$adjustNode
    )
  })
  
  dagitty_open_exp_outcome_paths_causal <- reactive({
    dagitty_has_required_nodes()
    
    purrr::safely(dagitty_open_paths_causal)(
      nodes = rvn$nodes, edges = rve$edges, exposure = input$exposureNode, 
      outcome = input$outcomeNode, adjusted = input$adjustNode
    )
  })
  
  dagitty_minimal_adjustment_sets <- reactive({
    dagitty_has_required_nodes()
    
    purrr::safely(dagitty_sets)(
      nodes = rvn$nodes, edges = rve$edges, exposure = input$exposureNode, 
      outcome = input$outcomeNode, adjusted = input$adjustNode
    )
  })
  
  dag_diagnostic_result <- function(label, ...) {
    fluidRow(
      class = "dag-diagnostic__result",
      tags$div(
        class = "col-sm-6 col-lg-4 dag-diagnostic__label",
        tags$p(tags$strong(label))
      ),
      tags$div(
        class = "col-sm-6 col-lg-8 dag-diagnostic__value",
        ...
      )
    )
  }
  
  output$dagExposureOutcomeDiagnositcs <- renderUI({
    validate(need(length(edges_in_dag(rve$edges, rvn$nodes)) > 0, ""))
    
    if ((input$debug_trigger %||% 0) > 0) browser()
    dagitty_has_required_nodes()
    
    open_paths <- dagitty_open_exp_outcome_paths()
    open_paths_causal <- dagitty_open_exp_outcome_paths_causal()
    adj_sets <- dagitty_minimal_adjustment_sets()
    
    validate(need(
      is.null(open_paths$error) | is.null(open_paths_causal$error),
      paste(
        "There was an error building your graph. It may not be fully or",
        "correctly specified. If you have special characters in your node",
        "change the node name to something short and representative. You can",
        "set more detailed node labels in the \"Tweak\" panel."
      )
    ), errorClass = " text-danger")
    
    open_paths_direct <- open_paths_causal$result
    open_paths_indirect <- setdiff(open_paths$result, open_paths_causal$result)
    adj_sets <- adj_sets$result
    cleaning_sets <- c()
    for(i in 1:length(adj_sets)){
      cleaning_sets <- c(cleaning_sets,paste0("{",adj_sets[[i]][1],",", adj_sets[[i]][2],"}"))
    }
    
    tagList(
      h4("Exposure and Outcome Information"),
      dag_diagnostic_result(
        label = "Minimal Adjustment Set", 
        if (cleaning_sets!="{NULL,NULL}") {
          paste(cleaning_sets, collapse=" ")
        } else helpText(
          "No minimal adjustment sets between exposure and outcome."
        )
      ),
      dag_diagnostic_result(
        label = "Open Causal Associations", 
        if (length(open_paths_direct)) {
          dagitty_format_paths(open_paths_direct)
        } else helpText(
          "No open causal associations between exposure and outcome."
        )
      ),
      dag_diagnostic_result(
        label = "Open Non-Causal Associations", 
        if (length(open_paths_indirect)) {
          dagitty_format_paths(open_paths_indirect)
        } else helpText(
          "No open non-causal associations between exposure and outcome."
        )
      )
    )
  })
  
  # ---- Tweak - Edge Aesthetics ----

  # Create the edge aesthetics control UI, only updated when tab is activated
  output$edge_aes_ui <- renderUI({
    req(input$shinydag_page == "tweak")
    req(length(isolate(rve$edges)) > 0)
    rv_edge_frame <- edge_frame(isolate(rve$edges), isolate(rvn$nodes)) %>% 
      arrange(from_name, to_name)
    
    tagList(
      purrr:::pmap(rv_edge_frame, ui_edge_controls_row, input = input)
    )
  })
  
  # Watch edge UI inputs and update rve$edges when inputs change
  observe({
    I("update edge aesthetics")
    req(length(rve$edges) > 0, grepl("^angle__", names(input)))
    rv_edges <- isolate(rve$edges)
    
    edge_ui <- get_hashed_input_with_prefix(
      input,
      prefix = "angle|color|lty|lineT",
      hash_sep = "__"
    )
    
    for (edge in edge_ui) {
      if (!edge$hash %in% names(rv_edges)) next
      this_edge <- edge[setdiff(names(edge), "hash")]
      for (prop in names(this_edge)) {
        if (is.na(this_edge[[prop]])) next
        rv_edges[[edge$hash]][[prop]] <- this_edge[[prop]]
      }
    }
    debug_input(bind_rows(rv_edges, .id = "hash"), "rve$edges after aes update")
    rve$edges <- rv_edges
  }, priority = -50)
  
  # ---- Tweak - Node Aesthetics ----
  
  # Create the node aesthetics control UI, only updated when tab is activated
  output$node_aes_ui <- renderUI({
    req(input$shinydag_page == "tweak")
    req(length(isolate(rvn$nodes)) > 0)
    rv_node_frame <- node_frame(isolate(rvn$nodes))
    
    tagList(
      purrr:::pmap(rv_node_frame, ui_node_controls_row, input = input)
    )
  })
  
  # Watch edge UI inputs and update rve$edges when inputs change
  observe({
    I("update node aesthetics")
    req(length(rvn$nodes) > 0, grepl("^color_fill_", names(input)))
    rv_nodes <- isolate(rvn$nodes)
    
    node_ui <- get_hashed_input_with_prefix(
      input,
      prefix = "name_latex|(color_(draw|fill|text))",
      hash_sep = "__"
    )
    
    for (node in node_ui) {
      if (!node$hash %in% names(rv_nodes)) next
      this_node <- node[setdiff(names(node), "hash")]
      for (prop in names(this_node)) {
        if (is.na(this_node[[prop]])) next
        rv_nodes[[node$hash]][[prop]] <- this_node[[prop]]
      }
    }
    debug_input(bind_rows(rv_nodes, .id = "hash"), "rvn$nodes after aes update")
    rvn$nodes <- rv_nodes
  }, priority = -50)
  
  
  # ---- Global - TikZ Code ----
  edge_points_rv <- reactive({
    req(length(rve$edges) > 0)
    ep <- edge_points(rve$edges, rvn$nodes)
    req(nrow(ep) > 0)
    ep
  })
  
  dag_node_lines <- function(nodeFrame) {
    dag_bounds <- 
      nodeFrame %>% 
      filter(!is.na(name)) %>% 
      summarize_at(vars(x, y), list(min = min, max = max))
    
    nodeFrame <- nodeFrame %>% 
      filter(
        between(x, dag_bounds$x_min, dag_bounds$x_max) &&
        between(y, dag_bounds$y_min, dag_bounds$y_max)
      )
    
    nodeFrame[is.na(nodeFrame$tikz_node), "tikz_node"] <- "~"
    
    nodeLines <- vector("character", 0)
    for (i in unique(nodeFrame$y)) {
      createLines <- paste0(
        paste(nodeFrame[nodeFrame$y == i, ]$tikz_node, collapse = " & "), 
        "  \\\\\n"
      )
      nodeLines <- c(nodeLines, createLines)
    }
    nodeLines <- rev(nodeLines)
    
    paste0(
      "\\matrix(m)[matrix of nodes, row sep=2.6em, column sep=2.8em,", 
      "text height=1.5ex, text depth=0.25ex]\n", 
      "{\n  ", paste(nodeLines, collapse = "  "), "};"
    )
  }
  
  tikz_node_points <- reactive({
    req(input$shinydag_page %in% c("tweak", "latex"))
    req(length(rvn$nodes))
    update_tikz_because_global_opts()
    node_df <- node_frame(rvn$nodes)
    req(nrow(node_df) > 0)
    node_frame_add_style(node_df)
  })
  
  tikz_code_from_app <- reactive({
    d_tikz_node_points <- debounce(tikz_node_points, 1000)
    nodePts <- d_tikz_node_points()
    req(nrow(nodePts) > 0)
    
    has_style <- any(!is.na(nodePts$tikz_style))
    tikz_style_defs <- nodePts$tikz_style[!is.na(nodePts$tikz_style)]
    
    styleZ <- paste(
      "\\tikzset{", 
      paste0("  every node/.style={ }", if (has_style) "," else "\n}"),
      if (has_style) paste(" ", tikz_style_defs, collapse = ",\n"),
      if (has_style) "}",
      sep = "\n"
    )
    startZ <- "\\begin{tikzpicture}[>=latex]"
    endZ <- "\\end{tikzpicture}"
    pathZ <- "\\path[->,font=\\scriptsize,>=angle 90]"
    
    d_x <- min(nodePts$x) - 1L
    d_y <- min(nodePts$y) - 1L
  
    nodePts$x <- nodePts$x - d_x
    nodePts$y <- nodePts$y - d_y
    
    y_max <- max(nodePts$y)
    
    nodeLines <- nodePts %>% 
      tidyr::complete(
        x = seq(min(nodePts$x), max(nodePts$x)), 
        y = seq(min(nodePts$y), max(nodePts$y))
      ) %>% 
      dag_node_lines()
    
    edgeLines <- character()
    
    if (length(edges_in_dag(rve$edges, isolate(rvn$nodes)))) {
      # edge_points_rv() is a reactive that gathers values from aesthetics UI
      # but it can be noisy, so we're debouncing to delay TeX rendering until values are constant
      edgePts <- debounce(edge_points_rv, 5000)()
      
      tikz_point <- function(x, y, d_x, d_y, y_max) {
        glue::glue("(m-{y_max - (y - d_y) + 1}-{x - d_x})")
      }
      
      edgePts <- edgePts %>%
        mutate(
          parent = tikz_point(from.x, from.y, d_x, d_y, y_max),
          child = tikz_point(to.x, to.y, d_x, d_y, y_max),
          edgeLine = glue::glue(
            "{parent} edge [>={input$arrowShape}, bend left = {edgePts$angle}, ",
            "color = {edgePts$color},{edgePts$lineT},{edgePts$lty}] node[auto] {{$~$}} {child}"
          )
        )
      
      debug_input(select(edgePts, hash, matches("^(from|to)_name"), parent, child, edgeLine), "edgeLines")
      edgeLines <- edgePts$edgeLine
    }
    
    edgeLines <- paste0(pathZ, paste(edgeLines, collapse = ""), ";")
    
    paste(c(styleZ, startZ, nodeLines, edgeLines, endZ), collapse = "\n")
  })
  
  make_graph <- function(nodes, edges) {
    g <- make_empty_graph()
    if (nrow(node_frame(nodes))) {
      g <- g + node_vertices(nodes)
    }
    if (length(edges)) {
      # Add edges
      g <- g + edge_edges(edges, nodes)
    }
    g
  }
  
  # ---- Tweak - Global Options ----
  update_tikz_because_global_opts <- reactiveVal(FALSE)
  
  observe({
    I("update tex_opts")
    `%|%` <- function(x, y) {
      x <- x %||% y
      if (is.na(x)) y else x
    }
    tex_opts$set(list(
      density = 1200,
      margin = list(
        left = input$tex_opts_margin_left %|% 0,
        top = input$tex_opts_margin_bottom %|% 0, # bug?
        right = input$tex_opts_margin_right %|% 0,
        bottom = input$tex_opts_margin_top %|% 0
      ),
      cleanup = c("aux", "log")
    ))
    update_tikz_because_global_opts(!isolate(update_tikz_because_global_opts()))
  })

  # ---- Tweak - dagitty DAG ----
  dag_dagitty <- reactive({
    req(
      tweak_preview_visible(),
      length(nodes_in_dag(rvn$nodes)), 
      length(edges_in_dag(rve$edges)),
      input$exposureNode, input$outcomeNode, input$adjustNode
    )
    make_dagitty(rvn$nodes, rve$edges, input$exposureNode, input$outcomeNode, input$adjustNode)
  })
  
  dag_tidy <- reactive({
    req(
      tweak_preview_visible(),
      length(nodes_in_dag(rvn$nodes)), 
      length(edges_in_dag(rve$edges)),
      input$exposureNode, input$outcomeNode, input$adjustNode
    )
    make_dagitty(rvn$nodes, rve$edges, input$exposureNode, input$outcomeNode, input$adjustNode) %>% 
      tidy_dagitty()
  })
  
  # ---- Tweak - Preview ----
  tweak_preview_visible <- callModule(
    module = dagPreview,
    id = "tweak_preview",
    session_dir = SESSION_TEMPDIR,
    tikz_code = reactive({
      req(input$shinydag_page == "tweak")
      tikz_code_from_app()
    }),
    dag_dagitty,
    dag_tidy,
    has_edges = reactive(nrow(edge_frame(rve$edges, rvn$nodes)))
  )
  
  # ---- LaTeX - Editor ----
  output$texEdit <- renderUI({
    tikz_lines <- tikz_code_from_app()
    
    if (is.null(tikz_lines)) {
      tikz_lines <- "\\\\begin{tikzpicture}[>=latex]\n\\\\end{tikzpicture}"
    } else {
      # double escape backslashes
      tikz_lines <- gsub("\\", "\\\\", tikz_lines, fixed = TRUE)
    }
    aceEditor(
      "manual_tikz", 
      mode = "latex", 
      value = paste(tikz_lines, collapse = "\n"), 
      theme = "chrome",
      wordWrap = TRUE, 
      highlightActiveLine = TRUE
    )
  })
  
  latex_preview_visible <- callModule(
    module = dagPreview,
    id = "latex_preview",
    session_dir = SESSION_TEMPDIR,
    reactive({
      req(input$shinydag_page == "latex")
      input$manual_tikz
    })
  )
  
  # ---- About - Examples ----
  example_value <- callModule(examples, "example")
  
  observe({
    req(example_value())
    
    ex_val <- example_value()
    rvn$nodes <- ex_val$nodes
    rve$edges <- ex_val$edges
    
    Sys.sleep(0.25)

    shinydashboard::updateTabItems(session, "shinydag_page", "sketch")
    
  })

}
