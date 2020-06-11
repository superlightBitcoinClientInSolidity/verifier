"""
Measure time elapsed between two checkpoints
"""

import time

class Timer:
    """
    Timer object
    _t = Timer()
    print(_t.peek())
    _t.pause()
    # do irrelevant stuff
    _t.unpause()
    del _t
    """

    def __init__(self):
        self.pause_on = False
        self.pause_start = 0
        self.pause_duration = 0
        self.start = time.time()

    def peek(self):
        """
        Displays the elapsed time without interfering with the time continuity
        """

        if self.pause_on is True:
            current_pause_duration = time.time()-self.pause_start
            elapsed = time.time()-self.start-self.pause_duration-current_pause_duration
        else:
            elapsed = time.time()-self.start-self.pause_duration
        print('{:5.5}'.format(elapsed), 'seconds have passed')

    def pause(self):
        """
        Pauses the timer
        """

        self.pause_on = True
        self.pause_start = time.time()

    def unpause(self):
        """
        Unpauses the timer
        """

        self.pause_on = False
        self.pause_duration += time.time()-self.pause_start

    def __del__(self):
        if self.pause_on is True:
            self.unpause()
        elapsed = time.time() - self.start - self.pause_duration
        print('Time elapsed: '+'{:5.5}'.format(elapsed), 'seconds', end=' ')
        if self.pause_duration > 0.001:
            print('(paused for '+'{:5.5f}'.format(self.pause_duration), 'seconds)', end=' ')
        print()
