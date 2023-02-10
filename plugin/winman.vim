vim9script

g:winman_enabled = get(g:, 'winman_enabled', 1)
g:winman_explorer_width = get(g:, 'winman_explorer_width', 30)
g:winman_window_width = get(g:, 'winman_window_width', 80)
g:winman_explorer_filetype = get(g:, 'winman_explorer_filetype', 'nerdtree')

export def Find(items: list<any>, Pred: func(any): bool, start: number = 0, direction: number = 1): number
  var i = start
  while i >= 0 && i < len(items)
    if Pred(items[i])
      return i
    endif
    i += direction
  endwhile
  return -1
enddef

def WinLayout(): list<any>
  var [type, fragment] = winlayout()
  if type == 'leaf'
    type = 'col'
    fragment = [[type, fragment]]
  endif
  if type == 'col'
    type = 'row'
    fragment = [[type, fragment]]
  endif
  return [type, fragment]
enddef

def Flatten(fragment: list<any>): list<number>
  var result = []
  var unexplored = [fragment]
  while len(unexplored) > 0
    var [type, children] = remove(unexplored, -1)
    if type == 'leaf'
      add(result, children)
    else
      extend(unexplored, reverse(copy(children)))
    endif
  endwhile
  return result
enddef

def Filetypes(): dict<any>
  var fts = {}
  for i in range(winnr('$'))
    const nr = i + 1
    fts[win_getid(nr)] = getwinvar(nr, '&filetype')
  endfor
  return fts
enddef

def WinSplitMoveThunk(child: number, parent: number, rightbelow: bool = false, vertical: bool = false): string
  return printf("win_splitmove(%d, %d, {'vertical': %s, 'rightbelow': %s})", child, parent, vertical, rightbelow)
enddef

def MaxGroups(columns: number, window_width: number): number
  const max_groups = columns / window_width
  if columns % window_width >= max_groups - 1
    return max_groups
  endif
  return max_groups - 1
enddef

class Layout
  this.columns: number
  this.filetypes: dict<any>
  this.window: number
  this.previous_window: number
  this.window_count: number
  this.winman_explorer_filetype: string
  this.winman_explorer_width: number
  this.winman_window_width: number
  this.windows: list<number>
  this.group_sizes: list<number>
  this.thunks: list<string>

  def IsExplorer(win: number): bool
    return (this.filetypes)[win] == this.winman_explorer_filetype
  enddef

  def GroupWindows(group: number): list<number>
    var start = 0
    for i in range(group)
      start += this.group_sizes[i]
    endfor
    const end = start + this.group_sizes[group]
    return slice(this.windows, start, end)
  enddef

  def GroupOf(win: number): number
    var idx = index(this.windows, win)
    var sum = 0
    for i in range(len(this.group_sizes))
      sum += this.group_sizes[i]
      if idx < sum
        return i
      endif
    endfor
    return -1
  enddef

  def HasExplorer(): bool
    for i in range(this.group_sizes[0])
      if this.IsExplorer(this.windows[i])
        return true
      endif
    endfor
    return false
  enddef

  def MoveFrom(group: number, direction: number)
    const group_windows = this.GroupWindows(group)
    const target_group = group + direction
    const boundary_idx = direction == 1 ? -1 : 0
    const target_group_boundary_idx = direction == 1 ? 0 : -1
    const window = group_windows[boundary_idx]
    const target_group_windows = this.GroupWindows(target_group)
    const target_window = target_group_windows[target_group_boundary_idx]
    const is_below = min([group, target_group]) % 2 == 1
    add(this.thunks, WinSplitMoveThunk(window, target_window, is_below))
    this.group_sizes[group] -= 1
    this.group_sizes[target_group] += 1
  enddef

  def MoveToExplorerPosition(win: number)
    const group = this.GroupOf(win)
    const idx = index(this.windows, win)
    this.group_sizes[group] -= 1
    this.group_sizes[0] += 1
    remove(this.windows, idx)
    insert(this.windows, win, 0)
    add(this.thunks, 'wincmd H')
  enddef

  def MoveAfterVertical(parent: number, child: number)
    const child_group = this.GroupOf(child)
    const child_idx = index(this.windows, child)
    remove(this.windows, child_idx)
    this.group_sizes[child_group] -= 1
    const parent_group = this.GroupOf(parent)
    const parent_idx = index(this.windows, parent)
    const new_child_group = parent_group + 1
    const new_child_idx = parent_idx + 1
    insert(this.windows, child, new_child_idx)
    insert(this.group_sizes, 1, new_child_group)
    add(this.thunks, WinSplitMoveThunk(child, parent, true, true))
  enddef

  def MoveAfter(parent: number, child: number)
    const child_idx = index(this.windows, child)
    const child_group = this.GroupOf(child)
    this.group_sizes[child_group] -= 1
    remove(this.windows, child_idx)
    const parent_idx = index(this.windows, parent)
    const parent_group = this.GroupOf(parent)
    add(this.thunks, WinSplitMoveThunk(child, parent, parent_group % 2 == 1))
    this.group_sizes[parent_group] += 1
    insert(this.windows, child, parent_idx + 1)
    if this.IsExplorer(parent)
      this.MoveFrom(0, 1)
    endif
  enddef

  def PercolateFrom(group: number, group_deltas: list<number>, direction: number)
    var target_group = Find(group_deltas, (delta) => delta == 0, group, direction)
    while target_group != group
      var start_group = Find(this.group_sizes, (size) => size > 1, target_group - direction, -direction)
      var cur_group = start_group
      while cur_group != target_group
        this.MoveFrom(cur_group, direction)
        cur_group += direction
      endwhile
      target_group = start_group
    endwhile
  enddef

  def BalanceAfterInsert(parent: number, child: number)
    const group = this.GroupOf(child)
    const min_size = min(this.group_sizes[1 : ])
    var group_deltas = mapnew(this.group_sizes, (_, s) => s - min_size)
    group_deltas[0] = 1
    if group_deltas[group] == 0
      return
    endif
    const can_percolate_right = min(group_deltas[group : ]) == 0
    const can_percolate_left = min(group_deltas[0 : group]) == 0
    const group_windows = this.GroupWindows(group)
    if group_windows[-1] != parent && group_windows[-1] != child && can_percolate_right
      this.PercolateFrom(group, group_deltas, 1)
      this.BalanceAfterInsert(parent, child)
    elseif group_windows[0] != parent && group_windows[0] != child && can_percolate_left
      this.PercolateFrom(group, group_deltas, -1)
      this.BalanceAfterInsert(parent, child)
    elseif can_percolate_right
      this.PercolateFrom(group, group_deltas, 1)
    elseif can_percolate_left
      this.PercolateFrom(group, group_deltas, -1)
    endif
  enddef

  def BalanceBeforeRemove(group: number)
    var future_sizes = copy(this.group_sizes)
    future_sizes[group] -= 1
    const min_size = min(future_sizes[1 : ])
    var group_deltas = mapnew(future_sizes, (_, s) => s - min_size)
    group_deltas[0] = 0
    for direction in [1, -1]
      const max_group = Find(group_deltas, (d) => d == 2, group, direction)
      if max_group != -1
        this.PercolateFrom(max_group, group_deltas, -direction)
        return
      endif
    endfor
  enddef

  def AfterOpen()
    if this.window_count == 1
      return
    endif
    if this.IsExplorer(this.window)
      this.MoveToExplorerPosition(this.window)
      return
    endif
    const max_groups = MaxGroups(this.columns, this.winman_window_width)
    const has_explorer = this.HasExplorer()
    if this.window_count <= max_groups + (has_explorer ? 1 : 0)
      this.MoveAfterVertical(this.previous_window, this.window)
      return
    endif
    this.MoveAfter(this.previous_window, this.window)
    this.BalanceAfterInsert(this.previous_window, this.window)
  enddef

  def BeforeClose()
    const max_groups = MaxGroups(this.columns, this.winman_window_width)
    const has_explorer = this.HasExplorer()
    if this.window_count <= max_groups + (has_explorer ? 1 : 0)
      return
    endif
    this.BalanceBeforeRemove(this.GroupOf(this.window))
  enddef
endclass

def CaptureLayout(): Layout
  var filetypes = Filetypes()
  var explorer_ft = g:winman_explorer_filetype
  const [_, fragments] = WinLayout()
  var windows = []
  var group_sizes = []
  for group in range(len(fragments))
    var group_windows = Flatten(fragments[group])
    if group == 0 && indexof(group_windows, (_, w) => filetypes[w] == explorer_ft) == -1
      add(group_sizes, 0)
    endif
    if len(group_sizes) % 2 == 0
      reverse(group_windows)
    endif
    add(group_sizes, len(group_windows))
    extend(windows, group_windows)
  endfor
  return Layout.new(
    &columns, filetypes, win_getid(), win_getid(winnr('#')), winnr('$'), explorer_ft,
    g:winman_explorer_width, g:winman_window_width, windows, group_sizes, [])
enddef

export def g:WinmanAfterOpen()
  if g:winman_enabled == 0
    return
  endif
  var layout = CaptureLayout()
  layout.AfterOpen()
  for thunk in layout.thunks
    execute thunk
  endfor
enddef

export def g:WinmanBeforeClose()
  if g:winman_enabled == 0
    return
  endif
  var layout = CaptureLayout()
  layout.BeforeClose()
  for thunk in layout.thunks
    execute thunk
  endfor
enddef

augroup winman
  autocmd WinNew * :call g:WinmanAfterOpen()
  autocmd WinClosed * :call g:WinmanBeforeClose()
augroup END

export def g:RunWinmanTests()
  v:errors = []

  def MakeLayout(with_explorer: bool = true): Layout
    var columns = 256
    var filetypes = {1000: with_explorer ? 'nerdtree' : 'vim', 1001: 'vim', 1002: 'markdown', 1003: 'vim', 1004: 'vim'} 
    var window = 1001
    var previous_window = 1000
    var window_count = 5
    var winman_explorer_filetype = 'nerdtree'
    var winman_explorer_width = 30
    var winman_window_width = 80
    var windows = [1000, 1001, 1002, 1003, 1004]
    var group_sizes = with_explorer ? [1, 2, 1, 1] : [0, 3, 1, 1]
    var thunks = []
    var layout = Layout.new(columns, filetypes, window, previous_window, window_count,
      winman_explorer_filetype, winman_explorer_width, winman_window_width, windows, group_sizes, thunks)
    return layout
  enddef

  var layout = MakeLayout()
  var layout_without_explorer = MakeLayout(false)

  # IsExplorer
  assert_true(layout.IsExplorer(1000))
  assert_false(layout.IsExplorer(1001))

  # GroupOf
  assert_equal(layout.GroupOf(1000), 0)
  assert_equal(layout.GroupOf(1001), 1)
  assert_equal(layout.GroupOf(1002), 1)
  assert_equal(2, layout.GroupOf(1003))
  assert_equal(3, layout.GroupOf(1004))
  assert_equal(1, layout_without_explorer.GroupOf(1000))
  assert_equal(1, layout_without_explorer.GroupOf(1001))
  assert_equal(1, layout_without_explorer.GroupOf(1002))
  assert_equal(2, layout_without_explorer.GroupOf(1003))
  assert_equal(3, layout_without_explorer.GroupOf(1004))

  # GroupWindows
  assert_equal(layout.GroupWindows(0), [1000])
  assert_equal(layout.GroupWindows(1), [1001, 1002])

  # HasExplorer
  assert_true(layout.HasExplorer())

  # MoveFrom
  layout.MoveFrom(1, 1)
  assert_equal(layout.group_sizes, [1, 1, 2, 1])
  assert_equal(layout.GroupWindows(1), [1001])
  assert_equal(layout.GroupWindows(2), [1002, 1003])
  # assert_equal([], layout.thunks)
  layout.MoveFrom(2, -1)
  assert_equal(layout.group_sizes, [1, 2, 1, 1])
  assert_equal(layout.GroupWindows(1), [1001, 1002])
  assert_equal(layout.GroupWindows(2), [1003])
  # assert_equal([], layout.thunks)
  
  # MoveToExplorerPosition
  layout_without_explorer.MoveToExplorerPosition(1000)
  assert_equal([1, 2, 1, 1], layout_without_explorer.group_sizes)
  assert_equal(['wincmd H'], layout_without_explorer.thunks)

  # MoveAfterVertical
  layout_without_explorer = MakeLayout(false)
  layout_without_explorer.MoveAfterVertical(1003, 1001)
  assert_equal([0, 2, 1, 1, 1], layout_without_explorer.group_sizes)
  assert_equal([1000, 1002, 1003, 1001, 1004], layout_without_explorer.windows)

  # MoveAfter
  var layout_with_explorer = MakeLayout()
  layout_with_explorer.MoveAfter(1000, 1002)
  assert_equal([1, 2, 1, 1], layout_with_explorer.group_sizes)
  assert_equal([1000, 1002, 1001, 1003, 1004], layout_with_explorer.windows)
  assert_equal(2, len(layout_with_explorer.thunks))

  # PercolateFrom
  layout_without_explorer = MakeLayout(false)
  layout_without_explorer.PercolateFrom(1, [1, 2, 0, 0], 1)
  assert_equal([0, 2, 2, 1], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)
  # assert_equal([], layout_without_explorer.thunks)
  
  # BalanceAfterInsert
  layout_without_explorer = MakeLayout(false)
  layout_without_explorer.BalanceAfterInsert(1000, 1001)
  assert_equal([0, 1, 2, 2], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)

  # AfterOpen
  layout_without_explorer = MakeLayout(false)
  layout_without_explorer.AfterOpen()
  assert_equal([0, 1, 2, 2], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)

  # BalanceBeforeRemove
  layout_with_explorer = MakeLayout()
  layout_with_explorer.BalanceBeforeRemove(3)
  assert_equal([1, 1, 1, 2], layout_with_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_with_explorer.windows)

  # BeforeClose
  layout_with_explorer = MakeLayout()
  layout_with_explorer.window = 1004
  layout_with_explorer.BeforeClose()
  assert_equal([1, 1, 1, 2], layout_with_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_with_explorer.windows)

  def MakeLargeLayout(): Layout
    var columns = 256
    var filetypes = {1000: 'vim', 1001: 'vim', 1002: 'markdown', 1003: 'vim', 1004: 'vim', 1005: 'vim', 1006: 'vim'} 
    var window = 1006
    var previous_window = 1000
    var window_count = 7
    var winman_explorer_filetype = 'nerdtree'
    var winman_explorer_width = 30
    var winman_window_width = 80
    var windows = [1000, 1006, 1005, 1004, 1003, 1001]
    var group_sizes = [0, 3, 2, 2]
    var thunks = []
    return Layout.new(columns, filetypes, window, previous_window, window_count,
      winman_explorer_filetype, winman_explorer_width, winman_window_width, windows, group_sizes, thunks)
  enddef

  var large_layout = MakeLargeLayout()
  large_layout.MoveFrom(1, 1)
  assert_equal([0, 2, 3, 2], large_layout.group_sizes)
  assert_equal([1000, 1006, 1005, 1004, 1003, 1001], large_layout.windows)
  # echo large_layout.thunks

  echo v:errors
enddef
