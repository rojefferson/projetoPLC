var a = [34, 203, 3, 746, 200, 984, 198, 764, 9];
 
function bubbleSort()
{
    var swapped;
    do {
        swapped = false;
        for (var i=0; i < a.len() -1; i = i + 1) {
            if (a[i] > a[i+1]) {
                var temp = a[i];
                a[i] = a[i+1];
                a[i+1] = temp;
                swapped = true;
            }
        }
    } while (swapped);

}
 
bubbleSort();
a;
