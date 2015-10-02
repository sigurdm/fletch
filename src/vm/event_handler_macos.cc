// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

#if defined(FLETCH_TARGET_OS_MACOS)

#include "src/vm/event_handler.h"

#include <sys/event.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "src/vm/thread.h"

namespace fletch {

int EventHandler::Create() {
  return kqueue();
}

void EventHandler::Run() {
  struct kevent event = {};
  event.ident = read_fd_;
  event.flags = EV_ADD;
  event.filter = EVFILT_READ;
  kevent(fd_, &event, 1, NULL, 0, NULL);
  while (true) {
    int64 next_timeout;
    {
      ScopedMonitorLock locker(monitor_);
      next_timeout = next_timeout_;
    }

    timespec ts;
    timespec* interval = NULL;

    if (next_timeout != INT64_MAX) {
      next_timeout -= Platform::GetMicroseconds() / 1000;
      if (next_timeout < 0) next_timeout = 0;
      ts.tv_sec = next_timeout / 1000;
      ts.tv_nsec = (next_timeout % 1000) * 1000000;
      interval = &ts;
    }

    int status = kevent(fd_, NULL, 0, &event, 1, interval);

    HandleTimeouts();

    if (status != 1) continue;

    int filter = event.filter;
    int flags = event.flags;
    int fflags = event.fflags;

    if (event.ident == static_cast<uintptr_t>(read_fd_)) {
      if ((flags & EV_EOF) == 0) {
        char b;
        read(read_fd_, &b, 1);
        continue;
      } else {
        close(read_fd_);
        close(fd_);
        ScopedMonitorLock locker(monitor_);
        fd_ = -1;
        monitor_->Notify();
        return;
      }
    }

    word mask = 0;
    if (filter == EVFILT_READ) {
      mask = READ_EVENT;
      if ((flags & EV_EOF) != 0) {
        if (fflags != 0) {
          mask = ERROR_EVENT;
        } else {
          mask |= CLOSE_EVENT;
        }
      }
    } else if (filter == EVFILT_WRITE) {
      if ((flags & EV_EOF) != 0 && fflags != 0) {
        mask = ERROR_EVENT;
      } else {
        mask = WRITE_EVENT;
      }
    }

    Port* port = reinterpret_cast<Port*>(event.udata);
    Send(port, mask);
  }
}

}  // namespace fletch

#endif  // defined(FLETCH_TARGET_OS_MACOS)
