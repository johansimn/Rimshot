import os

/// `log stream --predicate 'subsystem == "local.rimshot"'` shows these.
let log = Logger(subsystem: "local.rimshot", category: "app")
