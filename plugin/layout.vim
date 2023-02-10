vim9script

import "./lib.vim"

const EXPLORER_FILETYPE = 'nerdtree'

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

def GetFts(): dict<any>
  var fts = {}
  for i in range(winnr('$'))
    const nr = i + 1
    fts[win_getid(nr)] = getwinvar(nr, '&filetype')
  endfor
  return fts
enddef

def IsExplorer(window: number, layout: dict<any>): bool
  return layout.filetypes[window] == EXPLORER_FILETYPE
enddef

def MakeLayout(winlayout: list<any> = winlayout(), filetypes: dict<any> = GetFts(), ideal_group_count: number = 4, has_explorer: bool = false): dict<any>
  var [type, fragment] = winlayout
  if type == 'leaf'
    type = 'col'
    fragment = [[type, fragment]]
  endif
  if type == 'col'
    type = 'row'
    fragment = [[type, fragment]]
  endif
  var all_windows = []
  var group_sizes = has_explorer ? [] : [0]
  for inner_fragment in fragment
    var windows = Flatten(inner_fragment)
    if len(group_sizes) % 2 == 0
      reverse(windows)
    endif
    add(group_sizes, len(windows))
    extend(all_windows, windows)
  endfor
  while len(group_sizes) < ideal_group_count
    add(group_sizes, 0)
  endwhile
  return {'filetypes': filetypes, 'ideal_group_count': ideal_group_count, 'windows': all_windows, 'group_sizes': group_sizes, 'thonks': []}
enddef

def GroupOf(window: number, layout: dict<any>): number
  var idx = index(layout.windows, window)
  var sum = 0
  for i in range(len(layout.group_sizes))
    sum += layout.group_sizes[i]
    if idx < sum
      return i
    endif
  endfor
  return -1
enddef

export def g:MoveAfter(parent: number, child: number, layout: dict<any> = MakeLayout())
  const child_idx = index(layout.windows, child)
  const child_group = GroupOf(child, layout)
  layout.group_sizes[child_group] -= 1
  remove(layout.windows, child_idx)

  const parent_idx = index(layout.windows, parent)
  const parent_group = GroupOf(parent, layout)
  var new_child_idx = parent_idx + 1
  var new_child_group = parent_group
  var thonk = ''

  if IsExplorer(child, layout)
    thonk = 'wincmd H'
    new_child_idx = 0
    new_child_group = 0
  endif

  if IsExplorer(parent, layout)
    new_child_group = 1
    if layout.group_sizes[1] == 0
      thonk = printf("win_splitmove(%d, %d, {'vertical': true, 'rightbelow': true})", child, parent)
    else
      thonk = printf("win_splitmove(%d, %d)", child, layout.windows[1])
    endif
  else
    thonk = printf("win_splitmove(%d, %d, {'rightbelow': %s})", child, parent, parent_group % 2 == 1)
  endif

  echo thonk
  add(layout.thonks, thonk)

  layout.group_sizes[new_child_group] += 1
  insert(layout.windows, child, new_child_idx)
  if len(layout.group_sizes) > layout.ideal_group_count && layout.group_sizes[-1] == 0
    remove(layout.group_sizes, -1)
  endif
enddef


