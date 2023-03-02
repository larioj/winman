vim9script

g:winman_enabled = get(g:, 'winman_enabled', 1)
g:winman_explorer_width = get(g:, 'winman_explorer_width', 30)
g:winman_window_width = get(g:, 'winman_window_width', 80)
g:winman_explorer_filetype = get(g:, 'winman_explorer_filetype', 'nerdtree')

def Find(items: list<any>, Pred: func(any): bool, start: number = 0, direction: number = 1): number
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
    fragment = [['leaf', fragment]]
  endif
  if type == 'col'
    type = 'row'
    fragment = [['col', fragment]]
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

def IsExplorer(layout: dict<any>, win: number): bool
  return (layout.filetypes)[win] == layout.winman_explorer_filetype
enddef

def GroupWindows(layout: dict<any>, group: number): list<number>
  var start = 0
  for i in range(group)
    start += layout.group_sizes[i]
  endfor
  const end = start + layout.group_sizes[group]
  return slice(layout.windows, start, end)
enddef

def GroupOf(layout: dict<any>, win: number): number
  var idx = index(layout.windows, win)
  var sum = 0
  for i in range(len(layout.group_sizes))
    sum += layout.group_sizes[i]
    if idx < sum
      return i
    endif
  endfor
  return -1
enddef

def HasExplorer(layout: dict<any>): bool
  for i in range(layout.group_sizes[0])
    if IsExplorer(layout, layout.windows[i])
      return true
    endif
  endfor
  return false
enddef

def MoveFrom(layout: dict<any>, group: number, direction: number)
  const group_windows = GroupWindows(layout, group)
  const target_group = group + direction
  const boundary_idx = direction == 1 ? -1 : 0
  const target_group_boundary_idx = direction == 1 ? 0 : -1
  const window = group_windows[boundary_idx]
  const target_group_windows = GroupWindows(layout, target_group)
  const target_window = target_group_windows[target_group_boundary_idx]
  const is_below = min([group, target_group]) % 2 == 1
  add(layout.thunks, WinSplitMoveThunk(window, target_window, is_below))
  layout.group_sizes[group] -= 1
  layout.group_sizes[target_group] += 1
enddef

def MoveToExplorerPosition(layout: dict<any>, win: number)
  const group = GroupOf(layout, win)
  const idx = index(layout.windows, win)
  layout.group_sizes[group] -= 1
  layout.group_sizes[0] += 1
  remove(layout.windows, idx)
  insert(layout.windows, win, 0)
  add(layout.thunks, 'wincmd H')
enddef

def MoveAfterVertical(layout: dict<any>, parent: number, child: number)
  const child_group = GroupOf(layout, child)
  const child_idx = index(layout.windows, child)
  remove(layout.windows, child_idx)
  layout.group_sizes[child_group] -= 1
  const parent_group = GroupOf(layout, parent)
  const parent_idx = index(layout.windows, parent)
  const new_child_group = parent_group + 1
  const new_child_idx = parent_idx + 1
  insert(layout.windows, child, new_child_idx)
  insert(layout.group_sizes, 1, new_child_group)
  add(layout.thunks, WinSplitMoveThunk(child, parent, true, true))
enddef

def MoveAfter(layout: dict<any>, parent: number, child: number)
  const child_idx = index(layout.windows, child)
  const child_group = GroupOf(layout, child)
  layout.group_sizes[child_group] -= 1
  remove(layout.windows, child_idx)
  const parent_idx = index(layout.windows, parent)
  const parent_group = GroupOf(layout, parent)
  add(layout.thunks, WinSplitMoveThunk(child, parent, parent_group % 2 == 1))
  layout.group_sizes[parent_group] += 1
  insert(layout.windows, child, parent_idx + 1)
  if IsExplorer(layout, parent)
    MoveFrom(layout, 0, 1)
  endif
enddef

def PercolateFrom(layout: dict<any>, group: number, group_deltas: list<number>, direction: number)
  var target_group = Find(group_deltas, (delta) => delta == 0, group, direction)
  while target_group != group
    var start_group = Find(layout.group_sizes, (size) => size > 1, target_group - direction, -direction)
    var cur_group = start_group
    while cur_group != target_group
      MoveFrom(layout, cur_group, direction)
      cur_group += direction
    endwhile
    target_group = start_group
  endwhile
enddef

def BalanceAfterInsert(layout: dict<any>, parent: number, child: number)
  const group = GroupOf(layout, child)
  const min_size = min(layout.group_sizes[1 : ])
  var group_deltas = mapnew(layout.group_sizes, (_, s) => s - min_size)
  group_deltas[0] = 1
  if group_deltas[group] == 0
    return
  endif
  const can_percolate_right = min(group_deltas[group : ]) == 0
  const can_percolate_left = min(group_deltas[0 : group]) == 0
  const group_windows = GroupWindows(layout, group)
  if group_windows[-1] != parent && group_windows[-1] != child && can_percolate_right
    PercolateFrom(layout, group, group_deltas, 1)
    BalanceAfterInsert(layout, parent, child)
  elseif group_windows[0] != parent && group_windows[0] != child && can_percolate_left
    PercolateFrom(layout, group, group_deltas, -1)
    BalanceAfterInsert(layout, parent, child)
  elseif can_percolate_right
    PercolateFrom(layout, group, group_deltas, 1)
  elseif can_percolate_left
    PercolateFrom(layout, group, group_deltas, -1)
  endif
enddef

def BalanceBeforeRemove(layout: dict<any>, group: number)
  var future_sizes = copy(layout.group_sizes)
  future_sizes[group] -= 1
  const min_size = min(future_sizes[1 : ])
  var group_deltas = mapnew(future_sizes, (_, s) => s - min_size)
  group_deltas[0] = 0
  for direction in [1, -1]
    const max_group = Find(group_deltas, (d) => d == 2, group, direction)
    if max_group != -1
      PercolateFrom(layout, max_group, group_deltas, -direction)
      return
    endif
  endfor
enddef

def AfterOpen(layout: dict<any>)
  if layout.window_count == 1
    return
  endif
  if IsExplorer(layout, layout.window)
    MoveToExplorerPosition(layout, layout.window)
    return
  endif
  const max_groups = MaxGroups(layout.columns, layout.winman_window_width)
  const has_explorer = HasExplorer(layout)
  if layout.window_count <= max_groups + (has_explorer ? 1 : 0)
    MoveAfterVertical(layout, layout.previous_window, layout.window)
    return
  endif
  MoveAfter(layout, layout.previous_window, layout.window)
  BalanceAfterInsert(layout, layout.previous_window, layout.window)
enddef

def BeforeClose(layout: dict<any>)
  const max_groups = MaxGroups(layout.columns, layout.winman_window_width)
  const has_explorer = HasExplorer(layout)
  if layout.window_count <= max_groups + (has_explorer ? 1 : 0)
    return
  endif
  BalanceBeforeRemove(layout, GroupOf(layout, layout.window))
enddef

def CaptureLayout(): dict<any>
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
  return {
    'columns': &columns,
    'filetypes': filetypes,
    'window': win_getid(),
    'previous_window': win_getid(winnr('#')),
    'window_count': winnr('$'),
    'winman_explorer_filetype': explorer_ft,
    'winman_explorer_width': g:winman_explorer_width,
    'winman_window_width': g:winman_window_width,
    'windows': windows,
    'group_sizes': group_sizes,
    'thunks': []
  }
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

  def MakeLayout(with_explorer: bool = true): dict<any>
    return {
      'columns': 256,
      'filetypes': {1000: with_explorer ? 'nerdtree' : 'vim', 1001: 'vim', 1002: 'markdown', 1003: 'vim', 1004: 'vim'},
      'window': 1001,
      'previous_window': 1000,
      'window_count': 5,
      'winman_explorer_filetype': 'nerdtree',
      'winman_explorer_width': 30,
      'winman_window_width': 80,
      'windows': [1000, 1001, 1002, 1003, 1004],
      'group_sizes': (with_explorer ? [1, 2, 1, 1] : [0, 3, 1, 1]),
      'thunks': []
    }
  enddef

  var layout = MakeLayout()
  var layout_without_explorer = MakeLayout(false)

  # IsExplorer
  assert_true(IsExplorer(layout, 1000))
  assert_false(IsExplorer(layout, 1001))

  # GroupOf
  assert_equal(GroupOf(layout, 1000), 0)
  assert_equal(GroupOf(layout, 1001), 1)
  assert_equal(GroupOf(layout, 1002), 1)
  assert_equal(2, GroupOf(layout, 1003))
  assert_equal(3, GroupOf(layout, 1004))
  assert_equal(1, GroupOf(layout_without_explorer, 1000))
  assert_equal(1, GroupOf(layout_without_explorer, 1001))
  assert_equal(1, GroupOf(layout_without_explorer, 1002))
  assert_equal(2, GroupOf(layout_without_explorer, 1003))
  assert_equal(3, GroupOf(layout_without_explorer, 1004))

  # GroupWindows
  assert_equal(GroupWindows(layout, 0), [1000])
  assert_equal(GroupWindows(layout, 1), [1001, 1002])

  # HasExplorer
  assert_true(HasExplorer(layout))

  # MoveFrom
  MoveFrom(layout, 1, 1)
  assert_equal(layout.group_sizes, [1, 1, 2, 1])
  assert_equal(GroupWindows(layout, 1), [1001])
  assert_equal(GroupWindows(layout, 2), [1002, 1003])
  # assert_equal([], layout.thunks)
  MoveFrom(layout, 2, -1)
  assert_equal(layout.group_sizes, [1, 2, 1, 1])
  assert_equal(GroupWindows(layout, 1), [1001, 1002])
  assert_equal(GroupWindows(layout, 2), [1003])
  
  # MoveToExplorerPosition
  MoveToExplorerPosition(layout_without_explorer, 1000)
  assert_equal([1, 2, 1, 1], layout_without_explorer.group_sizes)
  assert_equal(['wincmd H'], layout_without_explorer.thunks)

  # MoveAfterVertical
  layout_without_explorer = MakeLayout(false)
  MoveAfterVertical(layout_without_explorer, 1003, 1001)
  assert_equal([0, 2, 1, 1, 1], layout_without_explorer.group_sizes)
  assert_equal([1000, 1002, 1003, 1001, 1004], layout_without_explorer.windows)

  # MoveAfter
  var layout_with_explorer = MakeLayout()
  MoveAfter(layout_with_explorer, 1000, 1002)
  assert_equal([1, 2, 1, 1], layout_with_explorer.group_sizes)
  assert_equal([1000, 1002, 1001, 1003, 1004], layout_with_explorer.windows)
  assert_equal(2, len(layout_with_explorer.thunks))

  # PercolateFrom
  layout_without_explorer = MakeLayout(false)
  PercolateFrom(layout_without_explorer, 1, [1, 2, 0, 0], 1)
  assert_equal([0, 2, 2, 1], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)
  
  # BalanceAfterInsert
  layout_without_explorer = MakeLayout(false)
  BalanceAfterInsert(layout_without_explorer, 1000, 1001)
  assert_equal([0, 1, 2, 2], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)

  # AfterOpen
  layout_without_explorer = MakeLayout(false)
  AfterOpen(layout_without_explorer)
  assert_equal([0, 1, 2, 2], layout_without_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_without_explorer.windows)

  # BalanceBeforeRemove
  layout_with_explorer = MakeLayout()
  BalanceBeforeRemove(layout_with_explorer, 3)
  assert_equal([1, 1, 1, 2], layout_with_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_with_explorer.windows)

  # BeforeClose
  layout_with_explorer = MakeLayout()
  layout_with_explorer.window = 1004
  BeforeClose(layout_with_explorer)
  assert_equal([1, 1, 1, 2], layout_with_explorer.group_sizes)
  assert_equal([1000, 1001, 1002, 1003, 1004], layout_with_explorer.windows)

  def MakeLargeLayout(): dict<any>
    return {
      'columns': 256,
      'filetypes': {1000: 'vim', 1001: 'vim', 1002: 'markdown', 1003: 'vim', 1004: 'vim', 1005: 'vim', 1006: 'vim'},
      'window': 1006,
      'previous_window': 1000,
      'window_count': 7,
      'winman_explorer_filetype': 'nerdtree',
      'winman_explorer_width': 30,
      'winman_window_width': 80,
      'windows': [1000, 1006, 1005, 1004, 1003, 1001],
      'group_sizes': [0, 3, 2, 2],
      'thunks': []
    }
  enddef

  var large_layout = MakeLargeLayout()
  MoveFrom(large_layout, 1, 1)
  assert_equal([0, 2, 3, 2], large_layout.group_sizes)
  assert_equal([1000, 1006, 1005, 1004, 1003, 1001], large_layout.windows)

  echo v:errors
enddef
