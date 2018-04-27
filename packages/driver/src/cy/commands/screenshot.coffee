_ = require("lodash")
Promise = require("bluebird")
$ = require("jquery")

Screenshot = require("../../cypress/screenshot")
$utils = require("../../cypress/utils")

getViewportHeight = (state) ->
  Math.min(state("viewportHeight"), $(window).height())

getViewportWidth = (state) ->
  Math.min(state("viewportWidth"), $(window).width())

automateScreenshot = (options = {}) ->
  { runnable, timeout } = options

  titles = []

  ## if this a hook then push both the current test title
  ## and our own hook title
  if runnable.type is "hook"
    if runnable.ctx and (ct = runnable.ctx.currentTest)
      titles.push(ct.title, runnable.title)
  else
    titles.push(runnable.title)

  getParentTitle = (runnable) ->
    if p = runnable.parent
      if t = p.title
        titles.unshift(t)

      getParentTitle(p)

  getParentTitle(runnable)

  props = _.extend({
    titles: titles
    testId: runnable.id
  }, _.omit(options, "runnable", "timeout", "log"))

  automate = ->
    Cypress.automation("take:screenshot", props)

  if not timeout
    automate()
  else
    ## need to remove the current timeout
    ## because we're handling timeouts ourselves
    cy.clearTimeout("take:screenshot")

    automate()
    .timeout(timeout)
    .catch (err) ->
      $utils.throwErr(err, { onFail: options.log })
    .catch Promise.TimeoutError, (err) ->
      $utils.throwErrByPath "screenshot.timed_out", {
        onFail: options.log
        args: { timeout }
      }

scrollOverrides = (win, doc) ->
  originalOverflow = doc.documentElement.style.overflow
  originalBodyOverflowY = doc.body.style.overflowY
  originalX = win.scrollX
  originalY = win.scrollY

  ## overflow-y: scroll can break `window.scrollTo`
  if doc.body
    doc.body.style.overflowY = "visible"

  ## hide scrollbars
  doc.documentElement.style.overflow = "hidden"

  ->
    doc.documentElement.style.overflow = originalOverflow
    if doc.body
      doc.body.style.overflowY = originalBodyOverflowY
    win.scrollTo(originalX, originalY)

takeScrollingScreenshots = (scrolls, win, automationOptions) ->
  scrollAndTake = ({ y, clip }, index) ->
    win.scrollTo(0, y)
    options = _.extend({}, automationOptions, {
      current: index + 1
      total: scrolls.length
      clip: clip
    })
    automateScreenshot(options)

  Promise
  .mapSeries(scrolls, scrollAndTake)
  .then (results) ->
    _.last(results)

takeFullPageScreenshot = (state, automationOptions) ->
  win = state("window")
  doc = state("document")

  resetScrollOverrides = scrollOverrides(win, doc)

  docHeight = $(doc).height()
  viewportHeight = getViewportHeight(state)
  numScreenshots = Math.ceil(docHeight / viewportHeight)

  scrolls = _.map _.times(numScreenshots), (index) ->
    y = viewportHeight * index
    clip = if index + 1 is numScreenshots
      heightLeft = docHeight - (viewportHeight * index)
      {
        x: automationOptions.clip.x
        y: viewportHeight - heightLeft
        width: automationOptions.clip.width
        height: heightLeft
      }
    else
      automationOptions.clip

    { y, clip }

  takeScrollingScreenshots(scrolls, win, automationOptions)
  .finally(resetScrollOverrides)

takeElementScreenshot = (element, state, automationOptions) ->

takeScreenshot = (Cypress, state, screenshotConfig, options = {}) ->
  {
    blackout
    capture
    disableTimersAndAnimations
    scaleAppCaptures
    waitForCommandSynchronization
  } = screenshotConfig

  { runnable } = options

  appOnly = capture is "app" or capture is "fullpage"

  send = (event, props) ->
    new Promise (resolve) ->
      Cypress.action("cy:#{event}", props, resolve)

  getOptions = (isOpen) ->
    {
      id: runnable.id
      isOpen: isOpen
      appOnly: appOnly
      scale: if appOnly then scaleAppCaptures else true
      waitForCommandSynchronization: if appOnly then false else waitForCommandSynchronization
      disableTimersAndAnimations: disableTimersAndAnimations
      blackout: if appOnly then blackout else []
    }

  before = (capture) ->
    if disableTimersAndAnimations
      cy.pauseTimers(true)

    Screenshot.callBeforeScreenshot(state("document"))

    send("before:screenshot", getOptions(true))

  after = (capture) ->
    send("after:screenshot", getOptions(false))

    Screenshot.callAfterScreenshot(state("document"))

    if disableTimersAndAnimations
      cy.pauseTimers(false)

  automationOptions = _.extend({}, options, {
    capture: capture
    clip: {
      x: 0
      y: 0
      width: getViewportWidth(state)
      height: getViewportHeight(state)
    }
  })

  before(capture)
  .then ->
    if capture is "fullpage"
      takeFullPageScreenshot(state, automationOptions)
    else
      automateScreenshot(automationOptions)
  .finally ->
    after(screenshotConfig)

module.exports = (Commands, Cypress, cy, state, config) ->

  Cypress.on "runnable:after:run:async", (test, runnable) ->
    screenshotConfig = Screenshot.getConfig()
    ## we want to take a screenshot if we have an error, we're
    ## to take a screenshot and we are not interactive
    ## which means we're exiting at the end
    if test.err and screenshotConfig.screenshotOnRunFailure and not config("isInteractive")
      ## always capture runner on failure screenshots
      screenshotConfig.capture = "runner"
      takeScreenshot(Cypress, state, screenshotConfig, { runnable })

  Commands.addAll({
    screenshot: (name, userOptions = {}) ->
      if _.isObject(name)
        userOptions = name
        name = null

      ## TODO: handle hook titles
      runnable = state("runnable")

      options = _.defaults {}, userOptions, {
        log: true
        timeout: config("responseTimeout")
      }

      screenshotConfig = _.pick(options, "capture", "scaleAppCaptures", "disableTimersAndAnimations", "blackout", "waitForCommandSynchronization")
      screenshotConfig = Screenshot.validate(screenshotConfig, "cy.screenshot", options._log)
      screenshotConfig = _.extend(Screenshot.getConfig(), screenshotConfig)

      if options.log
        consoleProps = {
          options: userOptions
          config: screenshotConfig
        }

        options._log = Cypress.log({
          message: name
          consoleProps: ->
            consoleProps
        })

      takeScreenshot(Cypress, state, screenshotConfig, {
        runnable: runnable
        name: name
        log: options._log
        timeout: options.timeout
      })
      .then ({ path, size }) ->
        _.extend(consoleProps, {
          "Saved": path
          "Size": size
        })
      .return(null)
  })
