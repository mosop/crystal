require "event"

# :nodoc:
class Scheduler
  @@idle = [] of Scheduler
  @@all = [] of Scheduler
  @@idle_mutex = Mutex.new
  @[ThreadLocal]
  @@current = new(true)

  def initialize(@own_event_loop = false)
    @thread = LibPThread.self.address
    @runnables = [] of Fiber
    # = Mutex.new
    @wait_mutex = Mutex.new
    @wait_cv = ConditionVariable.new
    @reschedule_fiber = Fiber.new("reschedule #{LibPThread.self.address}") { loop { reschedule(true) } }
    @victim = 0
    @@all << self
  end

  def self.start
    scheduler = new
    @@current = scheduler
    @@idle_mutex.synchronize do
      @@idle << scheduler
    end
    scheduler.wait
    scheduler.reschedule
  end

  def self.current
    @@current.not_nil!
  end

  protected def wait
    @wait_mutex.synchronize do
      log "Waiting"
      @wait_cv.wait(@wait_mutex) if @runnables.empty?
      log "Received signal"
    end
  end

  def reschedule(is_reschedule_fiber = false)
    log "Reschedule"
    while true
      if runnable = @wait_mutex.synchronize { @runnables.pop? }
        log "Found in queue '#{runnable.name}'"
        runnable.resume
        break
      elsif @own_event_loop
        EventLoop.resume
        break
      else
        @@idle_mutex.synchronize do
          @@idle << self
        end
        if is_reschedule_fiber
          wait
        else
          log "Switching to rescheduling fiber %ld", @reschedule_fiber.object_id
          @reschedule_fiber.resume
          break
        end
      end
    end
    nil
  end

  def enqueue(fiber : Fiber, force = false)
    log "Enqueue '#{fiber.name}'"
    if idle_scheduler = @@idle_mutex.synchronize { @@idle.pop? }
      log "Found idle scheduler '%ld'", idle_scheduler.@thread
      idle_scheduler.enqueue_and_notify fiber
    elsif force
      # fiber.resume
      loop do
        @victim += 1
        @victim = 1 if @victim >= @@all.size
        sched = @@all[@victim]
        next if sched == self
        sched.enqueue_and_notify fiber
        break
      end
    else
      @wait_mutex.synchronize { @runnables << fiber }
    end
  end

  def enqueue_and_notify(fiber : Fiber)
    @wait_mutex.synchronize do
      @runnables << fiber
      @wait_cv.signal
    end
  end

  def enqueue(fibers : Enumerable(Fiber))
    @wait_mutex.synchronize { @runnables.concat fibers }
  end
end
