var items = [2,4,1,6,8,3,4,3,9,23,5,4];

function swap(firstIndex, secondIndex){
    var temp = items[firstIndex];
    items[firstIndex] = items[secondIndex];
    items[secondIndex] = temp;
}

function partition(left, right) {

    var pivot   = items[(right + left) / 2],
        i       = left,
        j       = right;


    while (i <= j) {

        while (items[i] < pivot) {
            i++;
        }

        while (items[j] > pivot) {
            j--;
        }

        if (i <= j) {
            swap(i, j);
            i++;
            j--;
        }
    }

    return i;
}

function quickSort(left, right) {

    var index;

    if (items.len > 1) {

        index = partition(left, right);

        if (left < index - 1) {
            quickSort(left, index - 1);
        }

        if (index < right) {
            quickSort(index, right);
        }

    }
}

quickSort(0, items.len - 1);
items;
